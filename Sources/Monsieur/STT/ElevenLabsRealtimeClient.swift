import Foundation

/// Streams microphone audio to ElevenLabs Scribe v2 Realtime over a websocket.
///
/// Protocol (`wss://api.elevenlabs.io/v1/speech-to-text/realtime`):
///   client -> `{"message_type":"input_audio_chunk","audio_base_64":...,"sample_rate":16000}`
///   server -> `{"message_type":"partial_transcript","text":...}`     (may change)
///             `{"message_type":"committed_transcript","text":...}`   (final for that segment)
///
/// `keyterms` biases recognition toward your glossary *before* transcription,
/// which fixes far more than repairing the text afterwards can.
final class ElevenLabsRealtimeClient: NSObject, SpeechRecognizer {

    /// Called on the main queue.
    var onEvent: ((SpeechEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var committedSegments: [String] = []
    private var latestPartial = ""
    private var isClosing = false
    private var hasStartedSession = false
    private var lastMessageAt = CFAbsoluteTimeGetCurrent()

    /// Kept so the session can be rebuilt without the caller's help.
    private var settings: Settings?
    private var reconnects = 0
    private var isReconnecting = false
    /// Audio captured while a replacement socket is being established. Without
    /// it, every reconnect would silently swallow a second or so of speech.
    private var pendingAudio: [Data] = []

    /// The service enforces an undocumented session time limit. Half-hour
    /// dictations are a stated use case, so hitting it has to be survivable
    /// rather than fatal: reconnect, keep the transcript so far, carry on. The
    /// cap exists only so a genuinely broken connection cannot spin forever.
    private static let maxReconnects = 20

    /// Test hook: `MONSIEUR_FORCE_RECONNECT=<n>` drops the socket after n
    /// audio chunks. Recovery paths that are never exercised are the ones that
    /// turn out not to work, and the real trigger is a limit the service does
    /// not document and will not hit on demand.
    private static let forceReconnectAfter: Int? = {
        ProcessInfo.processInfo.environment["MONSIEUR_FORCE_RECONNECT"].flatMap(Int.init)
    }()
    private var chunksSent = 0

    /// Everything committed so far, plus whatever is still in flight.
    var currentText: String {
        (committedSegments + (latestPartial.isEmpty ? [] : [latestPartial]))
            .joined(separator: " ")
    }

    /// Only the finalised segments.
    var committedText: String {
        committedSegments.joined(separator: " ")
    }

    // MARK: - Connect

    /// Realtime limits differ from batch: 50 terms, 20 Unicode code points
    /// per term. Keep the complete glossary for LLM post-processing; do not
    /// truncate a technical name into a different word just to fit the API.
    /// https://elevenlabs.io/docs/eleven-api/guides/cookbooks/speech-to-text/batch/keyterm-prompting
    static func keyterms(from glossary: [GlossaryEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in glossary {
            let term = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.unicodeScalars.count <= 20,
                  seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == 50 { break }
        }
        return result
    }

    static func connectionURL(settings: Settings) throws -> URL {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")
        var items: [URLQueryItem] = [
            .init(name: "model_id", value: settings.sttModel),
            .init(name: "audio_format", value: "pcm_16000"),
            .init(name: "commit_strategy", value: "vad"),
        ]
        if let lang = settings.sttLanguage, !lang.isEmpty {
            items.append(.init(name: "language_code", value: lang))
        }
        if settings.removeFillerWords {
            items.append(.init(name: "no_verbatim", value: "true"))
        }
        // Repeated params: the endpoint takes `keyterms` as a list.
        for term in keyterms(from: settings.glossary) {
            items.append(.init(name: "keyterms", value: term))
        }
        components?.queryItems = items

        guard let url = components?.url else { throw SpeechError.badURL }
        return url
    }

    func connect(settings: Settings) throws {
        guard !settings.elevenLabsAPIKey.isEmpty else { throw SpeechError.missingAPIKey("ElevenLabs") }
        self.settings = settings
        committedSegments = []
        latestPartial = ""
        isClosing = false
        isReconnecting = false
        reconnects = 0
        chunksSent = 0
        pendingAudio = []
        try openSocket(settings: settings)
    }

    /// A replacement socket must not reset the per-dictation retry budget.
    private func openSocket(settings: Settings) throws {
        let url = try Self.connectionURL(settings: settings)
        let omitted = settings.glossary.count - Self.keyterms(from: settings.glossary).count
        if omitted > 0 {
            Log.stt.info("omitting \(omitted, privacy: .public) glossary entries from realtime hints; full glossary retained for rewriting")
        }
        var request = URLRequest(url: url)
        request.setValue(settings.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 30

        hasStartedSession = false
        lastMessageAt = CFAbsoluteTimeGetCurrent()

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop(for: task)
        Log.stt.info("connecting to Scribe (\(settings.sttModel, privacy: .public))")
    }

    /// Replaces the socket without disturbing the transcript gathered so far.
    ///
    /// Done in two steps on purpose. Audio that has already been sent may still
    /// be sitting on the server untranscribed, and simply dropping the socket
    /// loses it -- that cost the opening words of the sentence every time this
    /// was tested. So the dying session is first asked to commit what it has,
    /// and kept receiving for a moment while it does; only then is it replaced.
    private func reconnect(reason: String) {
        guard !isClosing, !isReconnecting, let settings else { return }
        guard reconnects < Self.maxReconnects else {
            cancel()
            emit(.failed(.transport("Lost the transcription connection and could not re-establish it.")))
            return
        }
        isReconnecting = true   // send() starts buffering from here
        reconnects += 1
        Log.stt.info("reconnecting (\(self.reconnects, privacy: .public)): \(reason, privacy: .public)")

        var drain: TimeInterval = 0
        if let dying = task,
           let json = try? JSONSerialization.data(withJSONObject: [
               "message_type": "input_audio_chunk",
               "audio_base_64": "",
               "commit": true,
           ]),
           let text = String(data: json, encoding: .utf8) {
            dying.send(.string(text)) { _ in }
            drain = 1.2
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + drain) { [weak self] in
            self?.completeReconnect(settings: settings)
        }
    }

    private func completeReconnect(settings: Settings) {
        guard isReconnecting, !isClosing else { return }

        // Captured after the drain window, so it includes anything the old
        // session managed to commit on its way out.
        var carried = committedSegments
        let inFlight = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inFlight.isEmpty { carried.append(inFlight) }

        let dying = task
        task = nil
        dying?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil

        do {
            try openSocket(settings: settings)
        } catch {
            cancel()
            emit(.failed(.transport(error.localizedDescription)))
            return
        }
        // The transcript belongs to the dictation, not to the socket.
        committedSegments = carried
        latestPartial = ""
        self.settings = settings
        isReconnecting = false

        let buffered = pendingAudio
        pendingAudio = []
        for chunk in buffered { send(pcm: chunk) }
    }

    // MARK: - Send

    func send(pcm: Data) {
        if isReconnecting || task == nil {
            guard !isClosing else { return }
            // Bound memory while a session is opening or being replaced.
            if pendingAudio.count < 200 { pendingAudio.append(pcm) }
            return
        }
        guard let task, !isClosing else { return }

        chunksSent += 1
        if let after = Self.forceReconnectAfter, chunksSent == after {
            reconnect(reason: "forced by MONSIEUR_FORCE_RECONNECT")
            return
        }

        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(),
            "sample_rate": 16_000,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: json, encoding: .utf8) else { return }
        task.send(.string(string)) { [weak self] error in
            // Before acceptance, the receive path owns connection errors and
            // can report invalid_request rather than a generic send failure.
            guard let self, let error, self.hasStartedSession,
                  !self.isClosing, self.task === task else { return }
            self.emit(.failed(.transport(error.localizedDescription)))
        }
    }

    /// Flushes the tail of the audio and waits for the recogniser to settle.
    /// There is no explicit "done" frame in the protocol, so we commit and then
    /// wait for the server to go quiet (or time out).
    func finish(timeout: TimeInterval) async -> String {
        // Stopping mid-reconnect would abandon the replacement socket and throw
        // away the audio buffered while it was being established. Let it land
        // first -- the whole point of reconnecting is not to lose anything.
        let reconnectDeadline = CFAbsoluteTimeGetCurrent() + 4
        while isReconnecting, CFAbsoluteTimeGetCurrent() < reconnectDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let task, !isClosing else { return committedText }
        isClosing = true

        let commit: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": "",
            "commit": true,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: commit),
           let string = String(data: json, encoding: .utf8) {
            try? await task.send(.string(string))
        }

        let commitSentAt = CFAbsoluteTimeGetCurrent()
        let deadline = commitSentAt + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(80))
            // Settle only once the server has answered the commit. Waiting on
            // "nothing for 500 ms" alone mistook the latency *before* the reply
            // for completion, and returned without the final words -- and any
            // segment committed earlier in the session was enough to satisfy the
            // old non-empty check, so the longer the dictation the more likely
            // it was to drop its own ending.
            guard lastMessageAt > commitSentAt else { continue }
            if CFAbsoluteTimeGetCurrent() - lastMessageAt > 0.5 { break }
        }

        // Whatever the recogniser never promoted is still better than dropping
        // it, whether or not anything was committed before it.
        let leftover = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty {
            committedSegments.append(leftover)
            latestPartial = ""
        }
        cancel()
        return committedText
    }

    func cancel() {
        isClosing = true
        hasStartedSession = false
        isReconnecting = false
        let dying = task
        task = nil
        dying?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        emit(.closed)
    }

    // MARK: - Receive

    private func receiveLoop(for socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self, self.task === socket else { return }
            switch result {
            case .failure(let error):
                if !self.isClosing {
                    self.reconnect(reason: error.localizedDescription)
                }
            case .success(let message):
                self.lastMessageAt = CFAbsoluteTimeGetCurrent()
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                @unknown default: break
                }
                self.receiveLoop(for: socket)
            }
        }
    }

    /// Internal so recorded server frames can be regression-tested offline.
    func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["message_type"] as? String else { return }

        switch type {
        case "session_started":
            hasStartedSession = true
            Log.stt.info("session started")
            emit(.connected)

        case "partial_transcript":
            let text = (object["text"] as? String) ?? ""
            latestPartial = text
            emit(.partial(text))

        case "committed_transcript":
            let text = ((object["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            latestPartial = ""
            guard !text.isEmpty else { return }
            committedSegments.append(text)
            emit(.committed(text))

        case "committed_transcript_with_timestamps",
             "final_transcript_with_timestamps",
             "committed_transcript_entities":
            break   // we do not use word timings

        default:
            if let message = Self.serverErrorMessage(in: object) {
                let combined = (type + " " + message).lowercased()
                if type == "session_time_limit_exceeded"
                    || (type != "invalid_request" && combined.contains("session") && combined.contains("limit")) {
                    reconnect(reason: "session time limit")
                    return
                }
                Log.stt.error("server error: \(message, privacy: .public)")
                // In particular, invalid_request is terminal: reconnecting
                // with the identical rejected options can never fix it.
                cancel()
                emit(.failed(.server(message)))
            }
        }
    }

    static func serverErrorMessage(in object: [String: Any]) -> String? {
        guard let type = object["message_type"] as? String,
              type.contains("error") || type == "invalid_request"
                || type == "session_time_limit_exceeded" else { return nil }
        return (object["message"] as? String) ?? (object["error"] as? String) ?? type
    }

    private func emit(_ event: SpeechEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
