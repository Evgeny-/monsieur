import Foundation

/// Everything about the app that is specific to one spoken language: what we
/// tell the recogniser to expect, and the words that end a recording or
/// introduce a spoken command.
///
/// Phrases are written the way a native speaker would actually say them, not
/// as a word-for-word translation of the English set -- "arrête
/// l'enregistrement" is what a French speaker says to stop a recording,
/// "stop l'enregistrement" is not.
struct LanguagePreset: Identifiable, Equatable {
    /// Stable key for pickers. Not the ISO code, because auto-detect does not
    /// have one.
    let id: String
    let displayName: String
    /// Goes straight into `Settings.sttLanguage`. Nil pins nothing -- the
    /// recogniser auto-detects instead.
    let sttLanguageCode: String?
    let stopPhrases: [String]
    let commandTriggers: [String]
}

extension LanguagePreset {

    static let autoDetect = LanguagePreset(
        id: "auto", displayName: "Auto-detect", sttLanguageCode: nil,
        // No language is pinned, so there is no single native-speaker
        // phrasing to draw on -- fall back to the tool's own UI language.
        stopPhrases: ["stop recording", "end recording"],
        commandTriggers: ["command", "listen up", "editor"])

    static let english = LanguagePreset(
        id: "eng", displayName: "English", sttLanguageCode: "eng",
        stopPhrases: ["stop recording", "end recording"],
        commandTriggers: ["command", "listen up", "editor"])

    static let french = LanguagePreset(
        id: "fra", displayName: "French", sttLanguageCode: "fra",
        stopPhrases: ["arrête l'enregistrement", "termine l'enregistrement"],
        commandTriggers: ["commande", "écoute", "éditeur"])

    static let german = LanguagePreset(
        id: "deu", displayName: "German", sttLanguageCode: "deu",
        stopPhrases: ["aufnahme stoppen", "aufnahme beenden"],
        commandTriggers: ["befehl", "hör zu", "editor"])

    static let spanish = LanguagePreset(
        id: "spa", displayName: "Spanish", sttLanguageCode: "spa",
        stopPhrases: ["detén la grabación", "termina la grabación"],
        commandTriggers: ["comando", "escucha", "editor"])

    static let portuguese = LanguagePreset(
        id: "por", displayName: "Portuguese", sttLanguageCode: "por",
        stopPhrases: ["pare a gravação", "termine a gravação"],
        commandTriggers: ["comando", "escuta", "editor"])

    static let italian = LanguagePreset(
        id: "ita", displayName: "Italian", sttLanguageCode: "ita",
        stopPhrases: ["ferma la registrazione", "termina la registrazione"],
        commandTriggers: ["comando", "ascolta", "editor"])

    static let russian = LanguagePreset(
        id: "rus", displayName: "Russian", sttLanguageCode: "rus",
        stopPhrases: [
            "стоп запись", "конец диктовки", "конец ввода", "конец текста",
            "ввод окончен", "ввод закончен",
        ],
        commandTriggers: ["команда", "слушай", "редактор"])

    static let ukrainian = LanguagePreset(
        id: "ukr", displayName: "Ukrainian", sttLanguageCode: "ukr",
        stopPhrases: ["стоп запис", "кінець диктування"],
        commandTriggers: ["команда", "слухай", "редактор"])

    static let polish = LanguagePreset(
        id: "pol", displayName: "Polish", sttLanguageCode: "pol",
        stopPhrases: ["stop nagrywanie", "koniec nagrywania"],
        commandTriggers: ["komenda", "słuchaj", "edytor"])

    static let dutch = LanguagePreset(
        id: "nld", displayName: "Dutch", sttLanguageCode: "nld",
        stopPhrases: ["stop opname", "einde opname"],
        commandTriggers: ["commando", "luister", "editor"])

    static let turkish = LanguagePreset(
        id: "tur", displayName: "Turkish", sttLanguageCode: "tur",
        stopPhrases: ["kaydı durdur", "kaydı bitir"],
        commandTriggers: ["komut", "dinle", "editör"])

    static let japanese = LanguagePreset(
        id: "jpn", displayName: "Japanese", sttLanguageCode: "jpn",
        stopPhrases: ["録音停止", "録音終了"],
        commandTriggers: ["コマンド", "聞いて", "エディター"])

    static let korean = LanguagePreset(
        id: "kor", displayName: "Korean", sttLanguageCode: "kor",
        stopPhrases: ["녹음 중지", "녹음 종료"],
        commandTriggers: ["명령", "들어봐", "에디터"])

    static let chinese = LanguagePreset(
        id: "zho", displayName: "Chinese", sttLanguageCode: "zho",
        stopPhrases: ["停止录音", "结束录音"],
        commandTriggers: ["命令", "听着", "编辑"])

    static let hindi = LanguagePreset(
        id: "hin", displayName: "Hindi", sttLanguageCode: "hin",
        stopPhrases: ["रिकॉर्डिंग बंद करो", "रिकॉर्डिंग रोको"],
        commandTriggers: ["कमांड", "सुनो", "एडिटर"])

    static let arabic = LanguagePreset(
        id: "ara", displayName: "Arabic", sttLanguageCode: "ara",
        stopPhrases: ["أوقف التسجيل", "أنهِ التسجيل"],
        commandTriggers: ["أمر", "استمع", "محرر"])

    /// Auto-detect first, since it is the lowest-commitment choice for anyone
    /// still deciding; the rest alphabetical by display name.
    static let all: [LanguagePreset] = [
        .autoDetect, .arabic, .chinese, .dutch, .english, .french, .german,
        .hindi, .italian, .japanese, .korean, .polish, .portuguese, .russian,
        .spanish, .turkish, .ukrainian,
    ]

    /// The preset pinning a given code, if any -- used to preselect a picker
    /// from settings already on disk. `nil` matches `.autoDetect`.
    static func matching(code: String?) -> LanguagePreset? {
        all.first { $0.sttLanguageCode == code }
    }

    /// True when `settings` already has exactly this preset's stop phrases
    /// and command triggers, i.e. applying it again would touch nothing.
    func matchesPhrases(in settings: Settings) -> Bool {
        settings.stopPhrases == stopPhrases && settings.commandTriggers == commandTriggers
    }

    /// Returns `settings` with the language code pinned and, optionally, the
    /// stop phrases and command triggers swapped in. Not `mutating` / inout:
    /// callers decide whether the result actually replaces anything, which
    /// keeps this safe to call speculatively (e.g. from a confirmation
    /// dialog's two buttons) without committing to either outcome up front.
    func applied(to settings: Settings, replacePhrases: Bool) -> Settings {
        var result = settings
        result.sttLanguage = sttLanguageCode
        if replacePhrases {
            result.stopPhrases = stopPhrases
            result.commandTriggers = commandTriggers
        }
        return result
    }
}


// MARK: - Target language

import SwiftUI

/// The language the rewriting stage produces.
///
/// A free-text field here was a small trap: "Eng", "english " and a typo all
/// silently change the prompt, and there is no feedback until the output comes
/// back in the wrong language. A value already in settings that is not on the
/// list is kept as its own entry rather than being quietly discarded.
struct TargetLanguagePicker: View {
    @Binding var language: String

    private var options: [String] {
        var names = LanguagePreset.all
            .filter { $0.sttLanguageCode != nil }
            .map(\.displayName)
        if !language.isEmpty, !names.contains(language) {
            names.insert(language, at: 0)
        }
        return names
    }

    var body: some View {
        Picker("Translate into", selection: $language) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
    }
}
