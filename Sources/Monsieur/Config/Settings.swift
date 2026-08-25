import Foundation

// MARK: - Model

enum LLMProvider: String, Codable, CaseIterable {
    case none, openai, anthropic, openrouter

    var label: String {
        switch self {
        case .none: return "Off (paste raw transcript)"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openrouter: return "OpenRouter"
        }
    }

    /// This stage runs on every single utterance and the work is not hard --
    /// translate, tidy, apply a glossary. Reach for a small fast model; a
    /// frontier one costs many times more for no gain you will notice.
    var suggestedModels: [String] {
        switch self {
        case .none: return []
        case .openai: return ["gpt-5.4-mini", "gpt-5.4"]
        case .anthropic: return ["claude-haiku-4-5", "claude-sonnet-5"]
        case .openrouter: return [
            "anthropic/claude-haiku-4.5",
            "google/gemini-2.5-flash",
            "openai/gpt-5.4-mini",
        ]
        }
    }
}

enum HotkeyMode: String, Codable, CaseIterable {
    /// Press once to start, press again to stop.
    case toggle
    /// Hold the key down while speaking, release to stop.
    case pushToTalk

    var label: String {
        switch self {
        case .toggle: return "Toggle (press to start, press to stop)"
        case .pushToTalk: return "Push to talk (hold)"
        }
    }
}

/// A term the recogniser tends to mangle.
struct GlossaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The spelling we want in the final text, e.g. "nginx".
    var canonical: String
    /// Optional known mishearings, e.g. ["engine x", "engine ex"].
    /// Leave empty and the model matches phonetically on its own.
    var heardAs: [String] = []

    enum CodingKeys: String, CodingKey { case canonical, heardAs }

    init(canonical: String, heardAs: [String] = []) {
        self.canonical = canonical
        self.heardAs = heardAs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canonical = try c.decode(String.self, forKey: .canonical)
        heardAs = (try? c.decode([String].self, forKey: .heardAs)) ?? []
    }
}

/// Wraps a glossary entry so a bad one costs only itself.
private struct LenientGlossaryEntry: Decodable {
    let value: GlossaryEntry?
    init(from decoder: Decoder) throws {
        value = try? GlossaryEntry(from: decoder)
    }
}

/// Everything the app knows, persisted as readable JSON so it can be edited by
/// hand as well as from the Settings window. Every field is optional on decode:
/// a hand-edited file missing keys still loads.
struct Settings: Codable, Equatable {

    // -- Speech to text --------------------------------------------------
    var sttProvider: STTProvider = .elevenlabs
    var elevenLabsAPIKey: String = ""
    var sttModel: String = "scribe_v2_realtime"
    /// OpenAI's streaming transcription model. `whisper-1` is batch only and
    /// cannot be used here.
    var openAISTTModel: String = "gpt-4o-transcribe"
    /// Which `LanguagePreset` supplied the stop phrases and command triggers.
    /// Deliberately separate from `sttLanguage`: knowing what you speak is
    /// useful for choosing those words, and is not a reason to constrain the
    /// recogniser.
    var languagePreset: String = "eng"
    /// False until the first-run setup has been completed.
    var hasCompletedSetup: Bool = false
    /// Pins the recogniser to one language. Normally nil, and normally should
    /// be: both services detect language automatically, and pinning is enforced
    /// rather than preferred -- speak something else and the recogniser forces
    /// what it hears into the pinned language instead of saying so. Which is
    /// the opposite of what this app is for.
    ///
    /// ISO-639 code, or nil to auto-detect.
    /// Pinning is more accurate if you always dictate in the same language;
    /// see `LanguagePreset` for the codes and phrases that ship with it.
    var sttLanguage: String? = nil
    /// Strips "um", "uh", "like", false starts at the recogniser level.
    var removeFillerWords: Bool = true

    // -- Post-processing (LLM) ------------------------------------------
    /// Off by default: rewriting needs its own API key on top of the
    /// transcription one, and a provider selected with no key behind it is
    /// indistinguishable from broken. First-run setup is what turns this on.
    var llmProvider: LLMProvider = .none
    var openAIAPIKey: String = ""
    var openAIModel: String = "gpt-5.4-mini"
    /// Sent as `reasoning_effort`. Empty string omits it entirely.
    var openAIReasoningEffort: String = "low"
    var anthropicAPIKey: String = ""
    var anthropicModel: String = "claude-haiku-4-5"
    /// Sent as `output_config.effort`. Empty omits it, which is the default:
    /// the small models this stage should be using reject the parameter, and
    /// sending it costs a refused request plus a retry on every dictation.
    var anthropicEffort: String = ""
    var openRouterAPIKey: String = ""
    var openRouterModel: String = "anthropic/claude-haiku-4.5"

    /// Language the finished text should be in.
    var targetLanguage: String = "English"
    /// Always appended to the system prompt. Your standing style preferences.
    var customInstructions: String = ""

    // -- Voice commands --------------------------------------------------
    /// Saying one of these starts an explicit instruction to the model.
    /// Everything up to the end of that sentence is treated as a command.
    /// English by default so a fresh clone works for anyone; first-run setup
    /// offers to swap these for another language's via `LanguagePreset`.
    var commandTriggers: [String] = LanguagePreset.english.commandTriggers
    /// Also let the model spot un-triggered meta-instructions on its own.
    var detectUntriggeredCommands: Bool = true

    // -- Glossary ---------------------------------------------------------
    /// Fed to ElevenLabs as `keyterms` (biases recognition) *and* to the LLM
    /// as a correction table (repairs what still came out wrong).
    var glossary: [GlossaryEntry] = []

    // -- Stopping ----------------------------------------------------------
    /// Saying one of these ends the recording. Matched on the live partial
    /// transcript and stripped from the final text. English by default; see
    /// `commandTriggers` above.
    var stopPhrases: [String] = LanguagePreset.english.stopPhrases
    var autoStopOnSilence: Bool = false
    var silenceSeconds: Double = 2.5
    /// Hard cap so a forgotten session cannot bill forever. An hour: long
    /// enough that a genuine half-hour dictation is never cut off, short enough
    /// that a hotkey pressed by accident does not run all day.
    var maxRecordingSeconds: Double = 3600

    // -- Hotkeys ------------------------------------------------------------
    /// e.g. "ctrl+alt+space", "cmd+shift+d", "f13".
    var hotkey: String = "ctrl+alt+space"
    var hotkeyMode: HotkeyMode = .toggle
    /// Second hotkey: same capture, but skips the LLM entirely and pastes the
    /// verbatim transcript. Empty string disables it.
    var rawHotkey: String = "ctrl+alt+shift+space"

    // -- Output --------------------------------------------------------------
    /// Paste via the clipboard (works everywhere, incl. Electron apps) instead
    /// of the Accessibility API (cleaner, but silently fails in many apps).
    var pasteViaClipboard: Bool = true
    /// Put the text on the clipboard and stop, instead of typing it.
    var copyOnly: Bool = false
    var playSounds: Bool = true
    var showHUD: Bool = true
    var hudStyle: HUDStyleID = .minimal
    /// Keeps a text label beside the menu bar icon. Off by default, but a
    /// crowded menu bar makes a lone monochrome glyph genuinely hard to find.
    var showMenuBarLabel: Bool = false
    var keepHistory: Bool = true

    // MARK: Decoding with per-field defaults

    enum CodingKeys: String, CodingKey {
        case elevenLabsAPIKey, sttModel, sttLanguage, removeFillerWords
        case sttProvider, openAISTTModel, hasCompletedSetup
        case languagePreset
        case llmProvider, openAIAPIKey, openAIModel, openAIReasoningEffort
        case anthropicAPIKey, anthropicModel, anthropicEffort
        case openRouterAPIKey, openRouterModel
        case targetLanguage, customInstructions
        case commandTriggers, detectUntriggeredCommands, glossary
        case stopPhrases, autoStopOnSilence, silenceSeconds, maxRecordingSeconds
        case hotkey, hotkeyMode, rawHotkey
        case pasteViaClipboard, copyOnly, playSounds, showHUD, keepHistory
        case hudStyle, showMenuBarLabel
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: k)) ?? fallback
        }
        sttProvider = v(.sttProvider, d.sttProvider)
        openAISTTModel = v(.openAISTTModel, d.openAISTTModel)
        hasCompletedSetup = v(.hasCompletedSetup, d.hasCompletedSetup)
        languagePreset = v(.languagePreset, d.languagePreset)
        elevenLabsAPIKey = v(.elevenLabsAPIKey, d.elevenLabsAPIKey)
        sttModel = v(.sttModel, d.sttModel)
        sttLanguage = (try? c.decodeIfPresent(String.self, forKey: .sttLanguage)) ?? nil
        removeFillerWords = v(.removeFillerWords, d.removeFillerWords)
        llmProvider = v(.llmProvider, d.llmProvider)
        openAIAPIKey = v(.openAIAPIKey, d.openAIAPIKey)
        openAIModel = v(.openAIModel, d.openAIModel)
        openAIReasoningEffort = v(.openAIReasoningEffort, d.openAIReasoningEffort)
        anthropicAPIKey = v(.anthropicAPIKey, d.anthropicAPIKey)
        anthropicModel = v(.anthropicModel, d.anthropicModel)
        anthropicEffort = v(.anthropicEffort, d.anthropicEffort)
        openRouterAPIKey = v(.openRouterAPIKey, d.openRouterAPIKey)
        openRouterModel = v(.openRouterModel, d.openRouterModel)
        targetLanguage = v(.targetLanguage, d.targetLanguage)
        customInstructions = v(.customInstructions, d.customInstructions)
        commandTriggers = v(.commandTriggers, d.commandTriggers)
        detectUntriggeredCommands = v(.detectUntriggeredCommands, d.detectUntriggeredCommands)
        // Decoded entry by entry. The whole array behind one `try?` meant a
        // single malformed line in a hand-edited file silently discarded every
        // other term in the glossary -- the failure mode you would least
        // expect and least notice.
        glossary = ((try? c.decode([LenientGlossaryEntry].self, forKey: .glossary)) ?? [])
            .compactMap(\.value)
        stopPhrases = v(.stopPhrases, d.stopPhrases)
        autoStopOnSilence = v(.autoStopOnSilence, d.autoStopOnSilence)
        silenceSeconds = v(.silenceSeconds, d.silenceSeconds)
        maxRecordingSeconds = v(.maxRecordingSeconds, d.maxRecordingSeconds)
        hotkey = v(.hotkey, d.hotkey)
        hotkeyMode = v(.hotkeyMode, d.hotkeyMode)
        rawHotkey = v(.rawHotkey, d.rawHotkey)
        pasteViaClipboard = v(.pasteViaClipboard, d.pasteViaClipboard)
        copyOnly = v(.copyOnly, d.copyOnly)
        playSounds = v(.playSounds, d.playSounds)
        showHUD = v(.showHUD, d.showHUD)
        hudStyle = v(.hudStyle, d.hudStyle)
        showMenuBarLabel = v(.showMenuBarLabel, d.showMenuBarLabel)
        keepHistory = v(.keepHistory, d.keepHistory)
    }

    // MARK: Derived

    var apiKeyForActiveProvider: String {
        switch llmProvider {
        case .none: return ""
        case .openai: return openAIAPIKey
        case .anthropic: return anthropicAPIKey
        case .openrouter: return openRouterAPIKey
        }
    }

    /// True when we have enough configuration to actually run the LLM stage.
    var llmEnabled: Bool {
        llmProvider != .none && !apiKeyForActiveProvider.isEmpty
    }
}
