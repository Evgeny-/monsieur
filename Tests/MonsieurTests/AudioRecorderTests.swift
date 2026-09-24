import AVFoundation
import Testing
@testable import Monsieur

private final class FakeCapture: AudioCapture {
    var onChunk: ((Data) -> Void)?
    var onError: ((Error) -> Void)?
    var sampleRate: Double?
    var stops = 0

    func start(sampleRate: Double, onChunk: @escaping (Data) -> Void,
               onError: @escaping (Error) -> Void) {
        self.sampleRate = sampleRate
        self.onChunk = onChunk
        self.onError = onError
    }

    func stop() { stops += 1 }

    @MainActor func waitUntilStarted() async throws {
        for _ in 0..<1000 {
            if onChunk != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AudioRecorder.RecorderError.startupTimedOut
    }
}

@Suite("Microphone startup lifecycle")
@MainActor
struct AudioRecorderTests {
    @Test func startupWaitsForPCMAndUsesTheRequestedRate() async throws {
        let capture = FakeCapture()
        let recorder = AudioRecorder(hasPermission: { true }, makeCapture: { capture })
        defer { recorder.stop() }
        recorder.targetSampleRate = 24_000
        var started = false
        var chunks: [Data] = []
        recorder.onChunk = { chunks.append($0) }
        let task = Task { try await recorder.start(); started = true }
        try await capture.waitUntilStarted()
        #expect(!started)
        #expect(capture.sampleRate == 24_000)
        capture.onChunk?(Data())
        await Task.yield()
        #expect(!started)
        let silence = Data(repeating: 0, count: 128)
        capture.onChunk?(silence)
        try await task.value
        #expect(started)
        #expect(chunks == [silence]) // silence is valid input; no need to speak
    }

    @Test func unresponsiveCaptureTimesOutAndStops() async {
        let capture = FakeCapture()
        let recorder = AudioRecorder(startupTimeout: .milliseconds(20),
                                     hasPermission: { true }, makeCapture: { capture })
        do {
            try await recorder.start()
            Issue.record("An input that delivers no audio must time out")
        } catch AudioRecorder.RecorderError.startupTimedOut {
            #expect(capture.stops == 1)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func stopDuringStartupCancelsTheWaitAndDropsLateAudio() async throws {
        let capture = FakeCapture()
        let recorder = AudioRecorder(hasPermission: { true }, makeCapture: { capture })
        var chunks = 0
        recorder.onChunk = { _ in chunks += 1 }
        let task = Task { try await recorder.start() }
        try await capture.waitUntilStarted()
        recorder.stop()
        capture.onChunk?(Data(repeating: 0, count: 128))
        do {
            try await task.value
            Issue.record("Stopped startup must not succeed")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        await Task.yield()
        #expect(chunks == 0)
        #expect(capture.stops == 1)
    }

    @Test func cancellingTheStartTaskStopsCapture() async throws {
        let capture = FakeCapture()
        let recorder = AudioRecorder(hasPermission: { true }, makeCapture: { capture })
        let task = Task { try await recorder.start() }
        try await capture.waitUntilStarted()
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled startup must not succeed")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(capture.stops == 1)
    }

    @Test func aFreshAttemptIgnoresTheOldCapturesCallbacks() async throws {
        let first = FakeCapture()
        let second = FakeCapture()
        var attempts = 0
        let recorder = AudioRecorder(hasPermission: { true }, makeCapture: {
            attempts += 1
            return attempts == 1 ? first : second
        })
        defer { recorder.stop() }
        let oldTask = Task { try await recorder.start() }
        try await first.waitUntilStarted()
        first.onError?(AudioRecorder.RecorderError.noInputDevice)
        do {
            try await oldTask.value
            Issue.record("Failed startup must throw")
        } catch AudioRecorder.RecorderError.noInputDevice {} catch {
            Issue.record("Unexpected error: \(error)")
        }
        let task = Task { try await recorder.start() }
        try await second.waitUntilStarted()
        var chunks: [Data] = []
        recorder.onChunk = { chunks.append($0) }
        first.onChunk?(Data([1, 0]))
        first.onError?(AudioRecorder.RecorderError.noInputDevice)
        second.onChunk?(Data([2, 0]))
        try await task.value
        #expect(chunks == [Data([2, 0])])
        #expect(first.stops == 1)
        #expect(second.stops == 0)
        #expect(attempts == 2)
    }

    @Test func runtimeFailureIsReportedOnceAndStopsCapture() async throws {
        let capture = FakeCapture()
        let recorder = AudioRecorder(hasPermission: { true }, makeCapture: { capture })
        var errors = 0
        recorder.onError = { _ in errors += 1 }
        let task = Task { try await recorder.start() }
        try await capture.waitUntilStarted()
        capture.onChunk?(Data([0, 0]))
        try await task.value
        capture.onError?(AudioRecorder.RecorderError.noInputDevice)
        capture.onError?(AudioRecorder.RecorderError.noInputDevice)
        // A main queue barrier drains both callbacks.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(errors == 1)
        #expect(capture.stops == 1)
    }

    @Test func deniedPermissionDoesNotOpenHardware() async {
        let recorder = AudioRecorder(hasPermission: { false }, makeCapture: {
            Issue.record("Must not open a device without permission")
            return FakeCapture()
        })
        do {
            try await recorder.start()
            Issue.record("Expected permission failure")
        } catch AudioRecorder.RecorderError.microphoneDenied {} catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("Microphone PCM contract")
struct MicrophonePCMTests {
    @Test(arguments: [16_000.0, 24_000.0])
    func outputSettingsMatchTheRecognizer(sampleRate: Double) throws {
        let format = try #require(AVAudioFormat(settings: MicrophoneCapture.audioSettings(sampleRate: sampleRate)))
        #expect(format.sampleRate == sampleRate)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatInt16)
        #expect(format.isInterleaved)
    }

    @Test(arguments: [16_000.0, 24_000.0])
    func copiesThePCMBytes(sampleRate: Double) throws {
        let bytes = Data([0, 0, 255, 127, 0, 128])
        let sample = try makeSample(bytes: bytes, sampleRate: sampleRate)
        #expect(try MicrophoneCapture.pcmData(from: sample, sampleRate: sampleRate) == bytes)
    }

    @Test func rejectsNativeRateAudioInsteadOfSendingItAs16kHz() throws {
        let sample = try makeSample(bytes: Data([0, 0]), sampleRate: 48_000)
        #expect(throws: AudioRecorder.RecorderError.self) {
            try MicrophoneCapture.pcmData(from: sample, sampleRate: 16_000)
        }
    }

    private func makeSample(bytes: Data, sampleRate: Double) throws -> CMSampleBuffer {
        let format = AudioRecorder.format(sampleRate: sampleRate)
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: 0, blockBufferOut: &block) == noErr)
        let buffer = try #require(block)
        bytes.withUnsafeBytes { pointer in
            #expect(CMBlockBufferReplaceDataBytes(with: pointer.baseAddress!, blockBuffer: buffer,
                offsetIntoDestination: 0, dataLength: bytes.count) == noErr)
        }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 2
        let audioDescription = try #require(description)
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: buffer, formatDescription: audioDescription,
            sampleCount: bytes.count / 2, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}
