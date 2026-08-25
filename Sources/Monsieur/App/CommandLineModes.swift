@preconcurrency import AVFoundation
import Foundation

/// Headless entry points, used for diagnosing a broken setup and for tuning the
/// prompt without having to speak into a microphone each time.
@MainActor
enum CommandLineModes {

    /// Diagnostics are piped as often as they are read on a terminal, and a
    /// block-buffered pipe hides exactly the progress you need when something
    /// hangs.
    static func unbufferOutput() {
        setvbuf(stdout, nil, _IONBF, 0)
    }

    // MARK: --process

    static func process(text: String, verbose: Bool) -> Int32 {
        let settings = SettingsStore.shared.settings
        let request = PromptBuilder.build(transcript: text, settings: settings, appName: nil)

        if verbose {
            print("──── system prompt ────\n\(request.system)")
            print("──── user message ────\n\(request.user)")
            print("──── output ────")
        }
        guard let processor = ProcessorFactory.make(for: settings) else {
            errorOut("No LLM provider configured (llmProvider is \"none\" or the key is missing).")
            return 1
        }
        return blocking {
            let started = Date()
            do {
                print(try await processor.process(request))
                if verbose {
                    print("──── \(String(format: "%.2f", Date().timeIntervalSince(started)))s ────")
                }
            } catch {
                errorOut(error.localizedDescription)
                return 1
            }
            return 0
        }
    }

    // MARK: --transcribe

    /// Streams a WAV file through the real websocket client and then the real
    /// rewriting stage: the same code paths the hotkey uses, minus the
    /// microphone and the paste.
    static func transcribe(path: String) -> Int32 {
        let settings = SettingsStore.shared.settings
        let pcm: Data
        do {
            pcm = try readPCM16Mono(at: path, sampleRate: settings.sttProvider.requiredSampleRate)
        } catch {
            errorOut(error.localizedDescription)
            return 1
        }
        let bytesPerSecond = settings.sttProvider.requiredSampleRate * 2
        print("audio: \(pcm.count) bytes (\(String(format: "%.1f", Double(pcm.count) / bytesPerSecond))s at \(Int(settings.sttProvider.requiredSampleRate)) Hz)")

        let client = ElevenLabsRealtimeClient()
        client.onEvent = { event in
            if case .failed(let error) = event { errorOut(error.localizedDescription) }
        }
        do {
            try client.connect(settings: settings)
        } catch {
            errorOut(error.localizedDescription)
            return 1
        }

        return blocking {
            // 100 ms of audio per frame, paced roughly like a live microphone.
            let frame = 3_200
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + frame, pcm.count)
                client.send(pcm: pcm.subdata(in: offset..<end))
                offset = end
                try? await Task.sleep(for: .milliseconds(25))
            }
            let started = Date()
            let transcript = await client.finish()
            print("transcript (\(String(format: "%.2f", Date().timeIntervalSince(started)))s to settle):")
            print("  \(transcript)")

            guard !transcript.isEmpty else {
                errorOut("Nothing was transcribed.")
                return 1
            }
            guard settings.llmEnabled, let processor = ProcessorFactory.make(for: settings) else {
                return 0
            }
            let llmStart = Date()
            do {
                let output = try await processor.process(
                    PromptBuilder.build(transcript: transcript, settings: settings, appName: nil))
                print("rewritten (\(String(format: "%.2f", Date().timeIntervalSince(llmStart)))s):")
                print("  \(output)")
            } catch {
                errorOut(error.localizedDescription)
                return 1
            }
            return 0
        }
    }

    // MARK: --check

    static func check() -> Int32 {
        let settings = SettingsStore.shared.settings
        print("settings.json  \(SettingsStore.fileURL.path)")
        line("Transcription", settings.sttProvider.label)
        let sttKey = settings.sttProvider == .elevenlabs
            ? settings.elevenLabsAPIKey : settings.openAIAPIKey
        line("Transcription key", sttKey.isEmpty ? nil : mask(sttKey))
        line("STT model", settings.sttProvider == .elevenlabs
            ? settings.sttModel : settings.openAISTTModel)
        line("Spoken language", settings.sttLanguage ?? "auto-detect")
        line("Rewriting", settings.llmProvider == .none ? "off" :
                "\(settings.llmProvider.rawValue) / " +
                (settings.llmProvider == .openai ? settings.openAIModel : settings.anthropicModel))
        line("LLM key", settings.llmProvider == .none ? "n/a" :
                (settings.apiKeyForActiveProvider.isEmpty ? nil : mask(settings.apiKeyForActiveProvider)))
        line("Target language", settings.targetLanguage)
        line("Glossary", "\(settings.glossary.count) term(s)")
        line("Hotkey", Hotkey.parse(settings.hotkey)?.display)
        line("Verbatim hotkey", settings.rawHotkey.isEmpty ? "disabled"
                : Hotkey.parse(settings.rawHotkey)?.display)

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        line("Microphone", mic == .authorized ? "granted"
                : (mic == .notDetermined ? "not asked yet" : nil))
        line("Accessibility", TextInserter.hasAccessibilityPermission ? "granted" : nil)
        return 0
    }

    // MARK: - Helpers

    private static func line(_ label: String, _ value: String?) {
        let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
        if let value {
            print("  ✓ \(padded) \(value)")
        } else {
            print("  ✗ \(padded) missing")
        }
    }

    private static func mask(_ key: String) -> String {
        key.count > 10 ? "\(key.prefix(8))…\(key.suffix(2))" : "set"
    }

    nonisolated private static func errorOut(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }

    /// Runs async work from a synchronous main-actor entry point. The task has
    /// to be detached: an inherited main-actor task would never get to run,
    /// because the semaphore below is holding the main actor hostage.
    /// Runs async work from a synchronous entry point.
    ///
    /// `@Sendable` is load-bearing, not decoration: without it the closure
    /// inherits `@MainActor` isolation from the enclosing context, so the
    /// detached task immediately hops back to the main thread -- which the
    /// semaphore below is holding -- and nothing ever runs.
    private static func blocking(timeout: TimeInterval = 90,
                                 _ body: @escaping @Sendable () async -> Int32) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: Int32 = 0
        Task.detached {
            status = await body()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            errorOut("timed out after \(Int(timeout))s")
            return 1
        }
        return status
    }

    /// Reads a WAV file and returns raw 16 kHz mono PCM16 samples, converting if
    /// the file is in some other format.
    private static func readPCM16Mono(at path: String, sampleRate: Double) throws -> Data {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: input)

        let target = AudioRecorder.format(sampleRate: sampleRate)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1024)
        else { throw CocoaError(.fileReadCorruptFile) }

        var error: NSError?
        var delivered = false
        converter.convert(to: output, error: &error) { _, status in
            if delivered { status.pointee = .noDataNow; return nil }
            delivered = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let channel = output.int16ChannelData else { throw CocoaError(.fileReadCorruptFile) }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
