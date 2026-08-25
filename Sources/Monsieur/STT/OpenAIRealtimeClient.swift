import Foundation

/// Streams microphone audio to OpenAI's Realtime API, configured as a
/// transcription-only session, over a websocket.
///
/// Protocol (`wss://api.openai.com/v1/realtime`, GA interface -- the older
/// beta interface, which used an `intent=transcription` query parameter and
/// an `OpenAI-Beta: realtime=v1` header, was retired in May 2026):
///   client -> `{"type":"session.update","session":{"type":"transcription",...}}`   (once, right after connecting)
///             `{"type":"input_audio_buffer.append","audio":<base64 PCM16>}`        (per chunk)
///             `{"type":"input_audio_buffer.commit"}`                               (see below)
///   server -> `{"type":"conversation.item.input_audio_transcription.delta","delta":...}`          (incremental text -- accumulate)
///             `{"type":"conversation.item.input_audio_transcription.completed","transcript":...}` (final text for that turn)
///
/// `turn_detection` is left `null` (manual commits) rather than
/// `server_vad`. Both worked examples in OpenAI's own transcription guide
/// configure it that way, and there are recent community reports of
/// gpt-live-transcribe rejecting or silently ignoring server-side VAD
/// despite the guide showing it elsewhere as a supported option. Manual
/// commit is unambiguously supported, so instead of depending on VAD to
/// segment speech into turns the way ElevenLabs' `commit_strategy=vad`
/// does, `send(pcm:)` below checkpoints with a commit of its own every
/// `commitInterval` seconds whenever there's uncommitted text. That's what
/// gives the HUD ElevenLabs-style progressively "locked in" text instead of
/// one giant provisional blob for the whole recording. An occasional
/// checkpoint landing mid-sentence is cosmetic, not a correctness issue --
/// `committedText` just joins the segments back together with spaces.
///
/// `keywords` biases recognition toward your glossary, the same job
/// ElevenLabs' `keyterms` does. `removeFillerWords` has no counterpart here:
/// these models transcribe verbatim by design and the API exposes no flag to
/// change that, so filler-word removal has to happen downstream, in LLM
/// post-processing, instead of at this layer.
///
/// Two more protocol facts drive most of what looks unusual below:
///  - Sessions are hard-closed by the server ~60 minutes after they open.
///    See `reconnect()`.
///  - Input audio must be 24 kHz PCM16 mono little-endian -- the API
///    documents "rate" as a fixed constant, not a configurable field. See
///    `sessionUpdatePayload`.
final class OpenAIRealtimeClient: NSObject, SpeechRecognizer {

    /// Called on the main queue.
    var onEvent: ((SpeechEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    /// Retained so a mid-recording session refresh (see `reconnect`) can
    /// rebuild the session config without the caller having to call
    /// `connect` again.
    private var settings: Settings?

    private var committedSegments: [String] = []
    private var latestPartial = ""
    /// The item currently accumulating into `latestPartial`. Delta events
    /// carry an `item_id`; when it changes, the server has started a new
    /// turn (e.g. right after a commit) and the accumulator must reset
    /// instead of appending onto the previous turn's text.
    private var currentItemID: String?

    private var isClosing = false
    /// True while `reconnect()` is swapping `task` for a new one ahead of
    /// OpenAI's session limit. `send(pcm:)` buffers into `pendingAudio`
    /// during this window rather than dropping chunks on the floor.
    private var isReconnecting = false
    private var pendingAudio: [Data] = []

    private var lastMessageAt = CFAbsoluteTimeGetCurrent()
    private var lastCommitAt = CFAbsoluteTimeGetCurrent()
    private var reconnectTask: Task<Void, Never>?

    /// OpenAI documents a hard 60-minute ceiling per realtime session. This
    /// schedules the first refresh purely as a fallback, in case
    /// `session.created` never reports `expires_at` for some reason;
    /// normally `handle(_:)` retargets `reconnectTask` to the server's real
    /// deadline the moment that field is seen.
    private static let fallbackSessionLifetime: TimeInterval = 55 * 60
    /// How far ahead of the deadline to cut over, so the handoff finishes
    /// with time to spare instead of racing the server's own cutoff.
    private static let reconnectLeadTime: TimeInterval = 120
    /// How often `send(pcm:)` checkpoints uncommitted text into a real
    /// commit. Purely cosmetic pacing for the HUD -- see the class doc
    /// comment -- not a protocol requirement.
    private static let commitInterval: TimeInterval = 12

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

    func connect(settings: Settings) throws {
        guard !settings.openAIAPIKey.isEmpty else { throw SpeechError.missingAPIKey("OpenAI") }

        self.settings = settings
        committedSegments = []
        latestPartial = ""
        currentItemID = nil
        pendingAudio = []
        isClosing = false
        isReconnecting = false
        lastMessageAt = CFAbsoluteTimeGetCurrent()
        lastCommitAt = CFAbsoluteTimeGetCurrent()

        try openSocket(settings: settings)
        Log.stt.info("connecting to OpenAI realtime transcription (\(settings.openAISTTModel, privacy: .public))")
        emit(.connected)
        scheduleReconnect(before: Date().addingTimeInterval(Self.fallbackSessionLifetime))
    }

    private func openSocket(settings: Settings) throws {
        // Two different models, in two different places. The query string names
        // the *session* model and must be a realtime one; the transcription
        // model goes inside, as audio.input.transcription.model. Passing the
        // transcription model here is refused by name: "gpt-4o-transcribe is a
        // transcription model and cannot be used as the realtime session
        // model".
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")
        components?.queryItems = [
            URLQueryItem(name: "model", value: settings.openAIRealtimeModel),
        ]
        guard let url = components?.url else { throw SpeechError.badURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        // Unlike a voice-agent session there's no `?model=...` query
        // parameter to set here -- for a transcription session the model
        // lives inside this message instead, under
        // audio.input.transcription.model.
        sendSessionUpdate(settings: settings, on: task)
        receiveLoop(task)
    }

    /// Session fields the server has refused this session; omitted on resend.
    private var droppedFields: Set<String> = []

    /// Recognises "The 'x' parameter is not supported…" and returns `x`.
    /// Internal rather than private so the string matching can be tested: it is
    /// the fragile half of the recovery, and the half that silently stops
    /// working if the wording changes.
    static func rejectedField(in message: String) -> String? {
        let known = ["languages", "keywords", "turn_detection", "format"]
        let lowered = message.lowercased()
        guard lowered.contains("not supported") || lowered.contains("unknown parameter")
        else { return nil }
        return known.first { lowered.contains("'\($0)'") || lowered.contains("\"\($0)\"") }
    }

    /// Builds the `session.update` body sent right after connecting.
    private func sessionUpdatePayload(settings: Settings) -> [String: Any] {
        var transcription: [String: Any] = ["model": settings.openAISTTModel]
        if let lang = settings.sttLanguage, !lang.isEmpty,
           !droppedFields.contains("languages") {
            // `languages` (plural) is the current hint field. OpenAI
            // deprecated the older singular `language` field and rejects a
            // session that sets both; a one-element array is how you pin a
            // single language now.
            transcription["languages"] = [lang]
        }
        let keywords = settings.glossary.map(\.canonical).filter { !$0.isEmpty }
        if !keywords.isEmpty, !droppedFields.contains("keywords") {
            transcription["keywords"] = keywords
        }

        let input: [String: Any] = [
            // 16-bit PCM, mono, little-endian, at exactly 24 kHz -- the API
            // documents "rate" as a constant, not a configurable field. The
            // capture side resamples to whatever the chosen provider needs
            // (see STTProvider.requiredSampleRate), so what arrives here
            // really is 24 kHz.
            "format": ["type": "audio/pcm", "rate": 24_000],
            "transcription": transcription,
            // See the class doc comment for why this is `null` rather than
            // `server_vad`.
            "turn_detection": NSNull(),
        ]

        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": input],
            ],
        ]
    }

    private func sendSessionUpdate(settings: Settings, on task: URLSessionWebSocketTask) {
        guard let string = serialize(sessionUpdatePayload(settings: settings)) else { return }
        sendString(string, on: task)
    }

    // MARK: - Session refresh

    /// OpenAI hard-closes a realtime session ~60 minutes after it opens (the
    /// current docs put the ceiling at 60 minutes; the now-retired beta
    /// capped sessions at 30). Dictations here can run up to an hour
    /// (`Settings.maxRecordingSeconds`), close enough to that ceiling that
    /// leaving it to the server would routinely cut off exactly the
    /// recordings this app is supposed to support -- silently truncating
    /// someone's dictation, which is the one outcome that isn't acceptable.
    /// So instead of surfacing the limit as an error, we open a replacement
    /// socket a couple of minutes ahead of the deadline, replay the session
    /// config, and keep accumulating into the same committed/partial state;
    /// the only visible effect should be a brief gap while the two sockets
    /// change hands. If the replacement socket itself can't connect, that
    /// failure is left to surface through the normal send/receive error
    /// paths below exactly as it would for the first connection -- not
    /// special-cased here -- so a genuine, persistent problem still ends up
    /// as `SpeechEvent.failed` rather than a silent hang.
    private func reconnect() async {
        guard let settings, !isClosing, !isReconnecting else { return }
        isReconnecting = true
        Log.stt.info("refreshing the OpenAI session ahead of its 60-minute limit")

        if let oldTask = task {
            await drain(oldTask)
            // Give the `.completed` event for whatever we just committed a
            // moment to arrive before pulling the socket out from under it.
            try? await Task.sleep(for: .milliseconds(500))
            oldTask.cancel(with: .goingAway, reason: nil)
        }
        session?.invalidateAndCancel()

        // The drain above should already have turned any trailing partial
        // into a committed segment via a `.completed` event. If the server
        // didn't answer in time, keep the words anyway rather than let the
        // new session's fresh item-id numbering silently discard them --
        // the same fallback `finish()` uses below.
        if !latestPartial.isEmpty {
            committedSegments.append(latestPartial)
            latestPartial = ""
        }
        currentItemID = nil

        do {
            try openSocket(settings: settings)
        } catch {
            emit(.failed(.transport("session refresh failed: \(error.localizedDescription)")))
            isReconnecting = false
            return
        }
        lastCommitAt = CFAbsoluteTimeGetCurrent()

        let queued = pendingAudio
        pendingAudio = []
        if let newTask = task {
            for chunk in queued { sendAppend(chunk, on: newTask) }
        }
        isReconnecting = false
    }

    private func scheduleReconnect(before deadline: Date) {
        reconnectTask?.cancel()
        let fireAt = deadline.addingTimeInterval(-Self.reconnectLeadTime)
        let delayMS = Int(max(1, fireAt.timeIntervalSinceNow) * 1000)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMS))
            guard let self, !Task.isCancelled else { return }
            await self.reconnect()
        }
    }

    /// Forces `task`'s server-side buffer to finalize into a transcript.
    /// Used both when the recording is really over (`finish`) and when
    /// retiring a socket ahead of the 60-minute cutoff (`reconnect`) -- both
    /// cases want the same thing: whatever audio hasn't yet been checkpointed
    /// turned into a transcript before the socket goes away.
    private func drain(_ task: URLSessionWebSocketTask) async {
        guard let string = serialize(["type": "input_audio_buffer.commit"]) else { return }
        try? await task.send(.string(string))
    }

    // MARK: - Send

    func send(pcm: Data) {
        guard !isClosing else { return }
        if isReconnecting {
            // Held here so the handoff in `reconnect()` doesn't cost audio;
            // flushed the moment the replacement socket is configured.
            pendingAudio.append(pcm)
            return
        }
        guard let task else { return }
        sendAppend(pcm, on: task)

        // No VAD to segment speech for us here (see the class doc comment),
        // so we checkpoint on our own clock instead of the server's.
        if !latestPartial.isEmpty, CFAbsoluteTimeGetCurrent() - lastCommitAt > Self.commitInterval {
            lastCommitAt = CFAbsoluteTimeGetCurrent()
            if let string = serialize(["type": "input_audio_buffer.commit"]) {
                sendString(string, on: task)
            }
        }
    }

    private func sendAppend(_ pcm: Data, on task: URLSessionWebSocketTask) {
        guard let string = serialize([
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString(),
        ]) else { return }
        sendString(string, on: task)
    }

    /// Flushes the tail of the audio and waits for the recogniser to settle.
    /// ElevenLabs leans on a synthetic "commit" chunk for this; OpenAI has a
    /// real `input_audio_buffer.commit` event, so `drain` sends that
    /// directly and then we fall into the same settle-or-timeout wait
    /// ElevenLabs uses.
    func finish(timeout: TimeInterval) async -> String {
        guard !isClosing else { return committedText }
        isClosing = true
        reconnectTask?.cancel()

        // A scheduled session refresh (see `scheduleReconnect`) may be
        // mid-flight; give it a moment to land so we drain the socket it
        // leaves behind instead of racing it. Bounded so this can never hang.
        var waited = 0
        while isReconnecting, waited < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }

        if let currentTask = task {
            await drain(currentTask)
        }

        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(80))
            // Settled: nothing new for 500 ms and we already have something.
            if CFAbsoluteTimeGetCurrent() - lastMessageAt > 0.5, !committedSegments.isEmpty {
                break
            }
        }

        // Anything the recogniser never promoted to committed is still
        // better than dropping it.
        if committedSegments.isEmpty, !latestPartial.isEmpty {
            committedSegments.append(latestPartial)
        }
        cancel()
        return committedText
    }

    func cancel() {
        isClosing = true
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        emit(.closed)
    }

    // MARK: - Receive

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.task === task else { return }   // superseded by a reconnect
            switch result {
            case .failure(let error):
                if !self.isClosing, !self.isReconnecting {
                    self.emit(.failed(.transport(error.localizedDescription)))
                }
            case .success(let message):
                self.lastMessageAt = CFAbsoluteTimeGetCurrent()
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                @unknown default: break
                }
                self.receiveLoop(task)
            }
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "session.created", "session.updated":
            if let sessionPayload = object["session"] as? [String: Any],
               let expiresAt = (sessionPayload["expires_at"] as? NSNumber)?.doubleValue {
                scheduleReconnect(before: Date(timeIntervalSince1970: expiresAt))
            }
            Log.stt.info("\(type, privacy: .public)")

        case "conversation.item.input_audio_transcription.delta":
            let itemID = object["item_id"] as? String
            if itemID != currentItemID {
                currentItemID = itemID
                latestPartial = ""
            }
            latestPartial += (object["delta"] as? String) ?? ""
            emit(.partial(latestPartial))

        case "conversation.item.input_audio_transcription.completed":
            let text = ((object["transcript"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentItemID = nil
            latestPartial = ""
            guard !text.isEmpty else { return }
            committedSegments.append(text)
            emit(.committed(text))

        case "conversation.item.input_audio_transcription.failed":
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "transcription failed"
            Log.stt.error("transcription failed: \(message, privacy: .public)")
            emit(.failed(.server(message)))

        case "input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped",
             "input_audio_buffer.committed", "conversation.item.created",
             "conversation.item.added", "conversation.item.done", "rate_limits.updated":
            break   // bookkeeping we don't need: item_id on the transcription events is enough

        case "error":
            let errorObject = object["error"] as? [String: Any]
            let code = errorObject?["code"] as? String
            // Expected, not a failure: our own checkpoint commits (see
            // `send(pcm:)`) race the server's own bookkeeping, so an
            // occasional commit lands after the buffer is already empty.
            guard code != "input_audio_buffer_commit_empty" else { return }
            let message = (errorObject?["message"] as? String) ?? type

            // A rejected session field is recoverable: the socket is open and
            // the session exists, only one setting was refused. Drop it and
            // resend the configuration rather than abandoning the recording --
            // which support for `languages` varies by model, so this is not a
            // hypothetical.
            if let field = Self.rejectedField(in: message), !droppedFields.contains(field) {
                droppedFields.insert(field)
                Log.stt.info("server refused '\(field, privacy: .public)'; resending session config without it")
                if let task, let settings { sendSessionUpdate(settings: settings, on: task) }
                return
            }

            Log.stt.error("server error: \(message, privacy: .public)")
            emit(.failed(.server(message)))

        default:
            break
        }
    }

    // MARK: - Helpers

    private func sendString(_ string: String, on task: URLSessionWebSocketTask) {
        task.send(.string(string)) { [weak self] error in
            guard let error else { return }
            self?.emit(.failed(.transport(error.localizedDescription)))
        }
    }

    private func serialize(_ object: [String: Any]) -> String? {
        guard let json = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    private func emit(_ event: SpeechEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
