import AVFoundation

/// start/stop enqueue their work and must never block the caller. Each instance
/// represents one attempt; callbacks may arrive after stop and must be fenced.
protocol AudioCapture: AnyObject {
    func start(sampleRate: Double, onChunk: @escaping (Data) -> Void,
               onError: @escaping (Error) -> Void)
    func stop()
}

/// AVCaptureSession opens only an explicit audio INPUT. Unlike AVAudioEngine,
/// it does not need the hidden aggregate of the default input and default output
/// (which can be rebuilt when a 3.5 mm headphone jack is plugged in).
final class MicrophoneCapture: NSObject, AudioCapture, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "monsieur.microphone.session")
    private let sampleQueue = DispatchQueue(label: "monsieur.microphone.samples")
    // Session state is owned by queue. Delegate configuration is set before
    // capture starts and never mutated while samples are being delivered.
    private var session: AVCaptureSession?
    private var observations: [NSObjectProtocol] = []
    private var sampleRate: Double = 16_000
    private var onChunk: ((Data) -> Void)?
    private var onError: ((Error) -> Void)?

    func start(sampleRate: Double, onChunk: @escaping (Data) -> Void,
               onError: @escaping (Error) -> Void) {
        queue.async {
            self.sampleRate = sampleRate
            self.onChunk = onChunk
            self.onError = onError
            do {
                guard let device = AVCaptureDevice.default(for: .audio) else {
                    throw AudioRecorder.RecorderError.noInputDevice
                }
                Log.audio.info("opening input: \(device.localizedName, privacy: .public)")
                let input = try AVCaptureDeviceInput(device: device)
                let session = AVCaptureSession()
                self.session = session
                let output = AVCaptureAudioDataOutput()
                // Let AVFoundation resample the device's native rate to the
                // recognizer's wire format (16 kHz ElevenLabs / 24 kHz OpenAI).
                output.audioSettings = Self.audioSettings(sampleRate: sampleRate)
                output.setSampleBufferDelegate(self, queue: self.sampleQueue)
                session.beginConfiguration()
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    throw AudioRecorder.RecorderError.noInputDevice
                }
                session.addInput(input)
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw AudioRecorder.RecorderError.invalidAudioFormat
                }
                session.addOutput(output)
                session.commitConfiguration()

                let center = NotificationCenter.default
                self.observations.append(center.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
                ) { notification in
                    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                    onError(error ?? AudioRecorder.RecorderError.noInputDevice)
                })
                self.observations.append(center.addObserver(
                    forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
                ) { _ in onError(AudioRecorder.RecorderError.noInputDevice) })
                session.startRunning()
                // Readiness is the first nonempty PCM chunk, not this return.
            } catch {
                self.tearDown()
                onError(error)
            }
        }
    }

    func stop() {
        // Retain until cleanup completes, even if the recorder has moved on.
        queue.async { self.tearDown() }
    }

    private func tearDown() {
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
        observations.removeAll()
        if let session {
            session.stopRunning()
            for output in session.outputs {
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(output)
            }
            for input in session.inputs { session.removeInput(input) }
        }
        session = nil
    }

    static func audioSettings(sampleRate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM,
         AVSampleRateKey: sampleRate,
         AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false,
         AVLinearPCMIsBigEndianKey: false,
         AVLinearPCMIsNonInterleaved: false]
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        do {
            let data = try Self.pcmData(from: sampleBuffer, sampleRate: sampleRate)
            if !data.isEmpty { onChunk?(data) }
        } catch { onError?(error) }
    }

    /// Copy rather than retain a capture-owned buffer. Also validate the actual
    /// format: malformed/native-rate bytes must never go to the STT service.
    static func pcmData(from sampleBuffer: CMSampleBuffer, sampleRate: Double) throws -> Data {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mSampleRate == sampleRate,
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16,
              format.mBytesPerFrame == 2,
              format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) == 0,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw AudioRecorder.RecorderError.invalidAudioFormat
        }
        let count = CMSampleBufferGetNumSamples(sampleBuffer) * 2
        guard CMBlockBufferGetDataLength(block) == count else {
            throw AudioRecorder.RecorderError.invalidAudioFormat
        }
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count,
                                       destination: bytes.baseAddress!)
        }
        guard status == noErr else { throw AudioRecorder.RecorderError.invalidAudioFormat }
        return data
    }
}
