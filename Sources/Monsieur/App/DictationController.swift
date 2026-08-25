import AppKit
import Combine

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let transcript: String
    let output: String
    let app: String?

    enum CodingKeys: String, CodingKey { case date, transcript, output, app }
}

/// The state machine for one dictation: hotkey -> record -> transcribe ->
/// rewrite -> type. Everything else in the app hangs off this.
@MainActor
final class DictationController: ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case working(String)      // user-facing status label
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .failed: return false
            case .recording, .working: return true
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// Segments the recogniser has finalised. These will not change.
    @Published private(set) var committedText: String = ""
    /// The segment still in flight. The recogniser may revise it at any moment,
    /// which is why designs render it differently -- greyed, dimmed, italic.
    @Published private(set) var partialText: String = ""

    /// Both parts, for anything that just wants the whole thing.
    var liveText: String {
        [committedText, partialText].filter { !$0.isEmpty }.joined(separator: " ")
    }
    @Published private(set) var level: Float = 0
    @Published private(set) var history: [HistoryEntry] = []

    private let recorder = AudioRecorder()
    private var stt: (any SpeechRecognizer)?
    private var bypassLLM = false
    private var targetApp: String?
    private var maxDurationTask: Task<Void, Never>?
    private var sttFailure: String?
    /// Set when stop arrives before recording has finished starting up. Without
    /// it, a quick push-to-talk tap would start a recording nothing ever stops.
    private var stopRequestedWhileStarting = false
    private var didPromptForAccessibility = false

    private var settings: Settings { SettingsStore.shared.settings }

    static let shared = DictationController()

    private init() {
        loadHistory()
    }

    // MARK: - Entry points

    func toggle(bypassLLM: Bool = false) {
        switch state {
        case .recording: stop()
        case .idle, .failed: start(bypassLLM: bypassLLM)
        case .working: break      // already in flight; ignore
        }
    }

    func start(bypassLLM: Bool = false) {
        guard !state.isBusy else { return }
        self.bypassLLM = bypassLLM
        stopRequestedWhileStarting = false
        // Set synchronously: start-up is async, and without this a second
        // hotkey press before it completes would begin a second recording.
        state = .working("Starting…")
        Task { await beginRecording() }
    }

    func stop() {
        switch state {
        case .recording:
            Task { await finishRecording() }
        case .working:
            stopRequestedWhileStarting = true
        case .idle, .failed:
            break
        }
    }

    /// Abandon everything without inserting anything.
    func cancel() {
        maxDurationTask?.cancel()
        recorder.stop()
        stt?.cancel()
        stt = nil
        clearLiveText()
        level = 0
        state = .idle
    }

    // MARK: - Recording

    private func beginRecording() async {
        guard !settings.elevenLabsAPIKey.isEmpty else {
            fail("No ElevenLabs API key yet. Open Settings and add one.")
            return
        }
        guard await AudioRecorder.requestMicrophoneAccess() else {
            fail("Microphone access denied. System Settings > Privacy & Security > Microphone.")
            return
        }
        if !TextInserter.hasAccessibilityPermission, !didPromptForAccessibility {
            // Not fatal -- we fall back to leaving the text on the clipboard --
            // but prompt now rather than after the user has spoken. Once per
            // launch only: this opens a system dialog, and doing it on every
            // dictation would be intolerable.
            didPromptForAccessibility = true
            TextInserter.requestAccessibilityPermission()
        }

        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        committedText = ""
        partialText = ""
        sttFailure = nil

        let client = RecognizerFactory.make(for: settings)
        client.onEvent = { [weak self] event in self?.handle(sttEvent: event) }
        do {
            try client.connect(settings: settings)
        } catch {
            fail(error.localizedDescription)
            return
        }
        stt = client

        recorder.onChunk = { [weak client] data in client?.send(pcm: data) }
        recorder.onLevel = { [weak self] value in self?.level = value }
        recorder.onSilence = { [weak self] in
            Log.app.info("auto-stopping after silence")
            self?.stop()
        }
        recorder.targetSampleRate = settings.sttProvider.requiredSampleRate
        recorder.silenceLimit = settings.silenceSeconds
        recorder.silenceDetectionEnabled = settings.autoStopOnSilence

        do {
            try recorder.start()
        } catch {
            client.cancel()
            stt = nil
            fail(error.localizedDescription)
            return
        }

        state = .recording
        play(.start)
        startMaxDurationTimer()

        if stopRequestedWhileStarting {
            stopRequestedWhileStarting = false
            await finishRecording()
        }
    }

    private func startMaxDurationTimer() {
        maxDurationTask?.cancel()
        let limit = settings.maxRecordingSeconds
        guard limit > 0 else { return }
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, case .recording = self.state else { return }
            Log.app.info("hit the \(limit, privacy: .public)s recording cap")
            self.stop()
        }
    }

    // MARK: - STT events

    private func handle(sttEvent event: SpeechEvent) {
        switch event {
        case .connected, .closed:
            break
        case .partial(let text):
            partialText = text
            checkForStopPhrase()
        case .committed:
            committedText = stt?.committedText ?? committedText
            partialText = ""
            checkForStopPhrase()
        case .failed(let error):
            // Keep the first failure. A refused connection is followed by a
            // generic "socket is not connected", and the later, emptier
            // message would otherwise be the one the user is shown.
            if sttFailure == nil { sttFailure = error.localizedDescription }
            Log.stt.error("\(error.localizedDescription, privacy: .public)")
            if case .recording = state { Task { await finishRecording() } }
        }
    }

    private func checkForStopPhrase() {
        guard case .recording = state else { return }
        let phrases = settings.stopPhrases.filter { !$0.isEmpty }
        guard !phrases.isEmpty else { return }
        let haystack = Self.normalise(liveText)
        for phrase in phrases where haystack.hasSuffix(Self.normalise(phrase)) {
            Log.app.info("stop phrase heard")
            stop()
            return
        }
    }

    // MARK: - Finishing

    private func finishRecording() async {
        maxDurationTask?.cancel()
        recorder.stop()
        play(.stop)
        state = .working("Transcribing…")

        let raw = await stt?.finish() ?? ""
        stt = nil
        level = 0

        let transcript = stripStopPhrases(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty else {
            clearLiveText()
            if let sttFailure {
                fail(sttFailure)
            } else {
                state = .idle
                Log.app.info("nothing was transcribed")
            }
            return
        }

        var output = transcript
        var warning: String?

        if !bypassLLM, settings.llmEnabled, let processor = ProcessorFactory.make(for: settings) {
            state = .working("Polishing…")
            do {
                let result = try await processor.process(
                    PromptBuilder.build(transcript: transcript,
                                        settings: settings,
                                        appName: targetApp))
                // An empty rewrite means the model dropped everything; the raw
                // words are a better outcome than silence.
                output = result.isEmpty ? transcript : result
            } catch {
                warning = error.localizedDescription
                Log.llm.error("post-processing failed: \(error.localizedDescription, privacy: .public)")
                output = transcript   // fall back to the verbatim transcript
            }
        }

        state = .working("Inserting…")
        let result = await TextInserter.insert(output, settings: settings)
        clearLiveText()

        record(HistoryEntry(date: Date(), transcript: transcript,
                            output: output, app: targetApp))

        switch result {
        case .inserted, .copiedOnly:
            if let warning {
                fail("Pasted the raw transcript — \(warning)")
            } else {
                state = .idle
            }
        case .failed(let message):
            // Hand the text back in a window rather than a toast that vanishes
            // in six seconds. The window is the notification, so no alert sound
            // and no lingering warning overlay on top of it -- go straight to
            // idle so the overlay clears immediately.
            Log.app.error("\(message, privacy: .public)")
            RecoveryWindowController.shared.present(text: output, reason: message)
            state = .idle
        }
    }

    private func clearLiveText() {
        committedText = ""
        partialText = ""
    }

    // MARK: - Stop phrases

    private func stripStopPhrases(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for phrase in settings.stopPhrases where !phrase.isEmpty {
            let target = Self.normalise(phrase)
            guard !target.isEmpty else { continue }
            // Walk back from the end and cut the suffix that normalises to the
            // stop phrase, so punctuation the recogniser added is removed too.
            let words = result.split(separator: " ")
            guard !words.isEmpty else { return "" }
            for take in 1...min(words.count, 8) {
                let tail = words.suffix(take).joined(separator: " ")
                if Self.normalise(tail) == target {
                    result = words.dropLast(take).joined(separator: " ")
                    break
                }
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:—-\n"))
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - History

    private func record(_ entry: HistoryEntry) {
        guard settings.keepHistory else { return }
        history.insert(entry, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        guard let line = try? JSONEncoder().encode(entry),
              var text = String(data: line, encoding: .utf8) else { return }
        text += "\n"
        let url = SettingsStore.historyURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    private func loadHistory() {
        guard let text = try? String(contentsOf: SettingsStore.historyURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        history = text.split(separator: "\n")
            .suffix(100)
            .compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
            .reversed()
    }

    // MARK: - Feedback

    private func fail(_ message: String) {
        Log.app.error("\(message, privacy: .public)")
        state = .failed(message)
        play(.error)
        Task {
            try? await Task.sleep(for: .seconds(6))
            if case .failed(let current) = state, current == message { state = .idle }
        }
    }

    private enum Cue: String {
        case start = "Tink"
        case stop = "Pop"
        // Basso is an alarm; these are notices, not alarms.
        case error = "Submarine"
    }

    private func play(_ cue: Cue) {
        guard settings.playSounds else { return }
        NSSound(named: cue.rawValue)?.play()
    }
}
