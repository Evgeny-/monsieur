import AVFoundation

/// Input-only capture. Headphones change the output route, not the microphone
/// selected in System Settings. No AVAudioEngine default input/output aggregate.
@MainActor
final class AudioRecorder {
    nonisolated static func format(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                      channels: 1, interleaved: true)!
    }

    /// Snapshotted at start; changing it mid-recording has no effect.
    var targetSampleRate: Double = 16_000
    /// All callbacks run on the main actor, including STT delivery.
    var onChunk: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onSilence: (() -> Void)?
    var onError: ((Error) -> Void)?
    var silenceLimit: TimeInterval = 2.5
    var silenceDetectionEnabled = false

    private let makeCapture: () -> any AudioCapture
    private let hasPermission: () -> Bool
    private let startupTimeout: Duration
    private var capture: (any AudioCapture)?
    private var sessionID: UUID?
    private var startup: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var noiseFloorDb: Float = -60
    private var lastSpeechAt: CFAbsoluteTime = 0
    private var hasHeardSpeech = false

    init(startupTimeout: Duration = .seconds(5),
         hasPermission: @escaping () -> Bool = {
             AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
         },
         makeCapture: @escaping () -> any AudioCapture = { MicrophoneCapture() }) {
        self.startupTimeout = startupTimeout
        self.hasPermission = hasPermission
        self.makeCapture = makeCapture
    }

    enum RecorderError: LocalizedError {
        case microphoneDenied
        case noInputDevice
        case invalidAudioFormat
        case startupTimedOut
        case alreadyStarted

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access was denied. Grant it in System Settings > Privacy & Security > Microphone."
            case .noInputDevice:
                return "No usable audio input device. Check Sound > Input in System Settings."
            case .invalidAudioFormat:
                return "The microphone could not provide mono PCM audio."
            case .startupTimedOut:
                return "The microphone did not start within 5 seconds. Check Sound > Input in System Settings and try again."
            case .alreadyStarted:
                return "Microphone capture is already starting or running."
            }
        }
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Wait for actual PCM, not merely a successful startRunning(). The timer
    /// runs independently of the queue that may be blocked inside Core Audio.
    func start() async throws {
        try Task.checkCancellation()
        guard sessionID == nil else { throw RecorderError.alreadyStarted }
        guard hasPermission() else { throw RecorderError.microphoneDenied }
        let id = UUID()
        let capture = makeCapture()
        self.capture = capture
        sessionID = id
        noiseFloorDb = -60
        hasHeardSpeech = false
        lastSpeechAt = CFAbsoluteTimeGetCurrent()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: self?.startupTimeout ?? .seconds(5)) }
                    catch { return }
                    self?.failed(RecorderError.startupTimedOut, session: id)
                }
                capture.start(sampleRate: targetSampleRate, onChunk: { [weak self] data in
                    DispatchQueue.main.async { self?.received(data, session: id) }
                }, onError: { [weak self] error in
                    DispatchQueue.main.async { self?.failed(error, session: id) }
                })
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.sessionID == id else { return }
                self?.stop()
            }
        }
    }

    /// Never waits on the hardware queue. Late callbacks are fenced by sessionID.
    func stop() {
        sessionID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = startup
        startup = nil
        capture?.stop()
        capture = nil
        pending?.resume(throwing: CancellationError())
    }

    private func failed(_ error: Error, session id: UUID) {
        guard sessionID == id else { return }
        let pending = startup
        startup = nil
        stop()
        if let pending { pending.resume(throwing: error) }
        else { onError?(error) }
    }

    private func received(_ data: Data, session id: UUID) {
        guard sessionID == id, !data.isEmpty else { return }
        if let pending = startup {
            startup = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            Log.audio.info("microphone is delivering PCM")
            pending.resume()
        }
        onChunk?(data)
        updateLevel(from: data)
    }

    private func updateLevel(from data: Data) {
        let rms: Float = data.withUnsafeBytes { bytes in
            let count = bytes.count / MemoryLayout<Int16>.size
            guard count > 0 else { return 0 }
            var sum: Double = 0
            for index in 0..<count {
                let sample = Int16(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: index * 2, as: Int16.self))
                let value = Double(sample) / 32768
                sum += value * value
            }
            return Float(sqrt(sum / Double(count)))
        }
        let db = rms > 0 ? 20 * log10(rms) : -100
        if db < noiseFloorDb { noiseFloorDb = db }
        else { noiseFloorDb += (db - noiseFloorDb) * 0.0005 }
        noiseFloorDb = max(noiseFloorDb, -70)

        let now = CFAbsoluteTimeGetCurrent()
        if db > max(noiseFloorDb + 12, -48) {
            hasHeardSpeech = true
            lastSpeechAt = now
        }
        onLevel?(min(max((db + 55) / 45, 0), 1))
        if silenceDetectionEnabled, hasHeardSpeech, now - lastSpeechAt > silenceLimit {
            silenceDetectionEnabled = false
            onSilence?()
        }
    }
}
