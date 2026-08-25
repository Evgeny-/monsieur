import Foundation

/// Which service turns audio into text.
enum STTProvider: String, Codable, CaseIterable {
    case elevenlabs
    case openai

    var label: String {
        switch self {
        case .elevenlabs: return "ElevenLabs Scribe"
        case .openai: return "OpenAI"
        }
    }

    /// The sample rate this service requires of the audio it is sent.
    /// ElevenLabs accepts a range and 16 kHz is plenty for speech; OpenAI's
    /// realtime endpoint documents 24 kHz as fixed.
    var requiredSampleRate: Double {
        switch self {
        case .elevenlabs: return 16_000
        case .openai: return 24_000
        }
    }

    /// Whether this provider can be used at all with the keys on hand.
    func isConfigured(_ settings: Settings) -> Bool {
        switch self {
        case .elevenlabs: return !settings.elevenLabsAPIKey.isEmpty
        case .openai: return !settings.openAIAPIKey.isEmpty
        }
    }
}

enum SpeechEvent {
    case connected
    /// The segment in flight. The recogniser may revise it at any moment.
    case partial(String)
    /// A finalised segment, appended to the transcript.
    case committed(String)
    case failed(SpeechError)
    case closed
}

enum SpeechError: LocalizedError {
    case missingAPIKey(String)
    case badURL
    case server(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No \(provider) API key. Add one in Settings."
        case .badURL:
            return "Could not build the transcription endpoint URL."
        case .server(let message): return message
        case .transport(let message): return "Connection failed: \(message)"
        }
    }
}

/// A streaming speech-to-text session.
///
/// Both supported services are websocket protocols that emit revisable partial
/// text followed by finalised segments, so one interface covers them and the
/// dictation flow never has to know which is in use.
protocol SpeechRecognizer: AnyObject {
    /// Called on the main queue.
    var onEvent: ((SpeechEvent) -> Void)? { get set }

    /// Finalised segments only.
    var committedText: String { get }
    /// Finalised segments plus whatever is still in flight.
    var currentText: String { get }

    func connect(settings: Settings) throws
    func send(pcm: Data)

    /// Flushes the tail of the audio, waits for the recogniser to settle, and
    /// returns the final transcript.
    func finish(timeout: TimeInterval) async -> String

    func cancel()
}

extension SpeechRecognizer {
    func finish() async -> String { await finish(timeout: 4.0) }
}

enum RecognizerFactory {
    static func make(for settings: Settings) -> SpeechRecognizer {
        switch settings.sttProvider {
        case .elevenlabs: return ElevenLabsRealtimeClient()
        case .openai: return OpenAIRealtimeClient()
        }
    }
}
