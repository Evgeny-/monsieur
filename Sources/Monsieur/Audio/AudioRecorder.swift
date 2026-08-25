import AVFoundation
import Accelerate

/// Captures the default input device and emits 16 kHz mono PCM16 chunks, which
/// is exactly what the ElevenLabs realtime endpoint wants (`pcm_16000`).
///
/// The tap has to use the input node's native format -- installing a tap with
/// any other format throws -- so resampling happens here via `AVAudioConverter`.
final class AudioRecorder {

    /// Mono signed 16-bit, little endian, interleaved, at whatever rate the
    /// chosen transcription service requires.
    static func format(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                      channels: 1, interleaved: true)!
    }

    /// Set before `start()`. Changing it mid-recording has no effect.
    var targetSampleRate: Double = 16_000

    private var targetFormat: AVAudioFormat { Self.format(sampleRate: targetSampleRate) }

    /// Fires on an arbitrary audio thread with resampled PCM16 bytes.
    var onChunk: ((Data) -> Void)?
    /// Fires on the main queue with a 0...1 level, for the HUD meter.
    var onLevel: ((Float) -> Void)?
    /// Fires on the main queue once the input has been quiet for `silenceLimit`.
    var onSilence: (() -> Void)?

    var silenceLimit: TimeInterval = 2.5
    var silenceDetectionEnabled = false

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    /// Speech gate, in dBFS. Anything quieter counts as silence.
    private var noiseFloorDb: Float = -60
    private var lastSpeechAt: CFAbsoluteTime = 0
    private var hasHeardSpeech = false

    enum RecorderError: LocalizedError {
        case microphoneDenied
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access was denied. Grant it in System Settings > Privacy & Security > Microphone."
            case .noInputDevice:
                return "No usable audio input device."
            }
        }
    }

    // MARK: - Permission

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphoneDenied
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        noiseFloorDb = -60
        hasHeardSpeech = false
        lastSpeechAt = CFAbsoluteTimeGetCurrent()

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, inputFormat: inputFormat)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        Log.audio.info("capture started: \(inputFormat.sampleRate, privacy: .public) Hz in, \(self.targetSampleRate, privacy: .public) Hz out")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        Log.audio.info("capture stopped")
    }

    // MARK: - Processing

    private func handle(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        updateLevel(from: buffer)

        guard let converter else { return }
        let format = targetFormat
        let ratio = format.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        var error: NSError?
        var delivered = false
        converter.convert(to: out, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.audio.error("resample failed: \(error.localizedDescription)")
            return
        }
        guard out.frameLength > 0, let channel = out.int16ChannelData else { return }

        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: channel[0], count: byteCount)
        onChunk?(data)
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let floats = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(floats[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let db = rms > 0 ? 20 * log10(rms) : -100

        // Slowly track the quiet baseline so the gate adapts to the room and mic.
        if db < noiseFloorDb { noiseFloorDb = db }
        else { noiseFloorDb += (db - noiseFloorDb) * 0.0005 }
        noiseFloorDb = max(noiseFloorDb, -70)

        let isSpeech = db > max(noiseFloorDb + 12, -48)
        let now = CFAbsoluteTimeGetCurrent()
        if isSpeech {
            hasHeardSpeech = true
            lastSpeechAt = now
        }

        // Map roughly -55..-10 dBFS onto 0...1 for the meter.
        let level = min(max((db + 55) / 45, 0), 1)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onLevel?(level)
            guard self.silenceDetectionEnabled, self.hasHeardSpeech, self.isRunning else { return }
            if now - self.lastSpeechAt > self.silenceLimit {
                self.silenceDetectionEnabled = false   // fire once per session
                self.onSilence?()
            }
        }
    }
}
