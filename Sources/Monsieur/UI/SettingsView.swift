import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared
    @ObservedObject var controller = DictationController.shared

    var body: some View {
        TabView {
            GeneralTab(store: store).tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionTab(store: store).tabItem { Label("Speech", systemImage: "waveform") }
            RewritingTab(store: store).tabItem { Label("Rewriting", systemImage: "text.quote") }
            GlossaryTab(store: store).tabItem { Label("Glossary", systemImage: "character.book.closed") }
            HistoryTab(controller: controller).tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @State private var accessibilityGranted = TextInserter.hasAccessibilityPermission

    var body: some View {
        Form {
            Section("Hotkeys") {
                HotkeyRecorder("Dictate", text: $store.settings.hotkey)

                Picker("Behaviour", selection: $store.settings.hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                HotkeyRecorder("Dictate verbatim", text: $store.settings.rawHotkey)
                    .help("Same capture, but skips the rewriting stage entirely. Leave empty to disable.")
            }

            Section("Stopping") {
                Toggle("Stop after a pause", isOn: $store.settings.autoStopOnSilence)
                if store.settings.autoStopOnSilence {
                    HStack {
                        Slider(value: $store.settings.silenceSeconds, in: 0.5...8, step: 0.5)
                        Text("\(store.settings.silenceSeconds, specifier: "%.1f") s")
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stop phrases, one per line").font(.caption).foregroundStyle(.secondary)
                    LineListEditor(lines: $store.settings.stopPhrases, height: 60)
                    Text("Saying one of these ends the recording. It is stripped from the text.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                Toggle("Paste via the clipboard", isOn: $store.settings.pasteViaClipboard)
                    .help("Works everywhere, including Electron apps. Turning this off uses the Accessibility API, which is cleaner but silently fails in many apps.")
                Toggle("Only copy, never type", isOn: $store.settings.copyOnly)
                Toggle("Play sounds", isOn: $store.settings.playSounds)
                Toggle("Show the on-screen indicator", isOn: $store.settings.showHUD)
                if store.settings.showHUD {
                    Picker("Overlay style", selection: $store.settings.hudStyle) {
                        ForEach(HUDStyleID.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    Text(store.settings.hudStyle.detail)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("Label the menu bar icon", isOn: $store.settings.showMenuBarLabel)
                    .help("Puts the app name beside the icon. A lone monochrome glyph is easy to lose in a crowded menu bar.")
                Toggle("Keep history", isOn: $store.settings.keepHistory)
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .red)
                    Text("Accessibility — required to type into other apps")
                    Spacer()
                    Button("Open Settings") { TextInserter.openAccessibilitySettings() }
                }
                HStack {
                    Spacer()
                    Button("Re-check") { accessibilityGranted = TextInserter.hasAccessibilityPermission }
                }
            }

            Section {
                HStack {
                    Button("Reveal settings.json") {
                        NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.fileURL])
                    }
                    Button("Import keys from a .env file…") { importEnv() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importEnv() { importEnvFile(into: store) }
}

/// Prompts for a `.env` file and imports whatever keys it finds into `store`.
/// Shared by the Settings window and first-run setup -- same action, two
/// entry points.
@MainActor
func importEnvFile(into store: SettingsStore) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.message = "Pick a .env file to read API keys from. Only empty fields are filled in."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let imported = store.importKeys(fromEnvFile: url)
    let alert = NSAlert()
    alert.messageText = imported.isEmpty
        ? "No new keys found."
        : "Imported: \(imported.joined(separator: ", "))."
    alert.runModal()
}

// MARK: - Transcription

private struct TranscriptionTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            // The provider lives here, not only in first-run setup. Hard-coding
            // an "ElevenLabs" section meant Settings claimed ElevenLabs no
            // matter which service was actually running -- so a provider set
            // during setup was invisible and unchangeable afterwards, and the
            // app could transcribe through OpenAI while this window insisted
            // otherwise.
            Section("Provider") {
                Picker("Transcribe with", selection: $store.settings.sttProvider) {
                    ForEach(STTProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                switch store.settings.sttProvider {
                case .elevenlabs:
                    SecretField(title: "ElevenLabs API key", text: $store.settings.elevenLabsAPIKey)
                    TextField("Model", text: $store.settings.sttModel)
                        .help("scribe_v2_realtime is the low-latency streaming model.")
                case .openai:
                    SecretField(title: "OpenAI API key", text: $store.settings.openAIAPIKey)
                    TextField("Model", text: $store.settings.openAISTTModel)
                        .help("gpt-4o-transcribe or gpt-4o-mini-transcribe. whisper-1 is batch only and cannot stream.")
                }
                if !store.settings.sttProvider.isConfigured(store.settings) {
                    Label("No API key for this provider — dictation will fail.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Section("Recognition") {
                LanguagePresetRow(settings: $store.settings)
                Text("Also offers to update the stop phrases (General → Stopping) and command trigger words (Rewriting → Spoken commands) to match.")
                    .font(.caption2).foregroundStyle(.secondary)
                TextField("Language code", text: Binding(
                    get: { store.settings.sttLanguage ?? "" },
                    set: { store.settings.sttLanguage = $0.isEmpty ? nil : $0 }))
                    .help("ISO 639 code such as rus or eng. Leave empty to auto-detect. Pinning is more accurate when you always speak one language — but it is enforced, not preferred: speak another and the recogniser forces what it hears into the pinned one rather than telling you.")
                Toggle("Drop filler words", isOn: $store.settings.removeFillerWords)
                    .help("Sends no_verbatim, which removes 'эм', 'ну', 'like' and false starts at the recogniser level.")
                HStack {
                    Text("Recording cap")
                    Spacer()
                    TextField("", value: Binding(
                        get: { store.settings.maxRecordingSeconds / 60 },
                        set: { store.settings.maxRecordingSeconds = max(1, $0) * 60 }),
                        format: .number.precision(.fractionLength(0)))
                        .frame(width: 60)
                    Text("minutes").foregroundStyle(.secondary)
                }
                Text("A safety net for a hotkey pressed by accident, not a limit on how long you can talk.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Text("Glossary terms are also sent as `keyterms`, which biases recognition before transcription happens — that fixes more than correcting the text afterwards can.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Picks a language preset and pins `sttLanguage` to it. Optionally offers to
/// also swap in that language's stop phrases and command trigger words -- but
/// only with confirmation, since those may have been hand-edited. Not shown:
/// picking the language a user is already on (or one with identical phrases,
/// e.g. re-picking Auto-detect on a fresh install) applies immediately with
/// no dialog, since there is nothing to protect in that case.
struct LanguagePresetRow: View {
    @Binding var settings: Settings
    @State private var pendingPreset: LanguagePreset?

    /// The preset matching what's currently pinned, or nil for a hand-typed
    /// code that isn't one of ours -- the picker shows that as "Custom"
    /// rather than silently snapping to something else.
    private var current: LanguagePreset? { LanguagePreset.matching(code: settings.sttLanguage) }

    var body: some View {
        Picker("Language preset", selection: Binding(
            get: { current?.id ?? "" },
            set: { id in
                guard let preset = LanguagePreset.all.first(where: { $0.id == id }) else { return }
                if preset.matchesPhrases(in: settings) {
                    settings = preset.applied(to: settings, replacePhrases: false)
                } else {
                    pendingPreset = preset
                }
            })) {
            if current == nil {
                Text("Custom").tag("")
            }
            ForEach(LanguagePreset.all) { preset in
                Text(preset.displayName).tag(preset.id)
            }
        }
        .confirmationDialog(
            "Also switch to \(pendingPreset?.displayName ?? "")'s stop phrases and command words?",
            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
            titleVisibility: .visible,
            presenting: pendingPreset) { preset in
                Button("Replace Them") { settings = preset.applied(to: settings, replacePhrases: true) }
                Button("Keep Mine") { settings = preset.applied(to: settings, replacePhrases: false) }
                Button("Cancel", role: .cancel) {}
            } message: { preset in
                Text("This overwrites the stop phrases and command trigger words below with \(preset.displayName)'s. \"Keep Mine\" only changes the recognition language.")
            }
    }
}

// MARK: - Rewriting

private struct RewritingTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Model") {
                Picker("Provider", selection: $store.settings.llmProvider) {
                    ForEach(LLMProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                switch store.settings.llmProvider {
                case .none:
                    Text("The verbatim transcript is inserted as-is. No translation, no clean-up.")
                        .font(.caption).foregroundStyle(.secondary)
                case .openai:
                    SecretField(title: "API key", text: $store.settings.openAIAPIKey)
                    TextField("Model", text: $store.settings.openAIModel)
                    TextField("Reasoning effort", text: $store.settings.openAIReasoningEffort)
                        .help("minimal / low / medium / high. Empty omits the parameter.")
                case .anthropic:
                    SecretField(title: "API key", text: $store.settings.anthropicAPIKey)
                    TextField("Model", text: $store.settings.anthropicModel)
                    TextField("Effort", text: $store.settings.anthropicEffort)
                        .help("low / medium / high / xhigh / max. Empty omits the parameter. Low keeps the round-trip short, which is what you feel between finishing a sentence and text appearing.")
                case .openrouter:
                    SecretField(title: "API key", text: $store.settings.openRouterAPIKey)
                    TextField("Model", text: $store.settings.openRouterModel)
                        .help("Any model OpenRouter serves, in provider/model form.")
                }
                if !store.settings.llmProvider.suggestedModels.isEmpty {
                    Text("Small and fast is the right call here — this runs on every utterance and the work is easy. Suggested: \(store.settings.llmProvider.suggestedModels.joined(separator: ", ")).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                TextField("Target language", text: $store.settings.targetLanguage)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Standing instructions").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $store.settings.customInstructions)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                    Text("Always applied. Unlike anything you say out loud, these are trusted.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("Spoken commands") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trigger words, one per line").font(.caption).foregroundStyle(.secondary)
                    LineListEditor(lines: $store.settings.commandTriggers, height: 70)
                }
                Toggle("Also detect untriggered asides",
                       isOn: $store.settings.detectUntriggeredCommands)
                    .help("Lets the model notice instructions like 'and make that more formal' without a trigger word. More natural, but it can occasionally swallow a phrase you meant to keep.")
                Text("Commands may only change how the text is written — language, tone, structure, formatting, terminology. Anything else stays in the text as ordinary words.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Glossary

private struct GlossaryTab: View {
    @ObservedObject var store: SettingsStore
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terms the recogniser gets wrong. Sent to ElevenLabs as recognition hints and to the model as a correction table.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal)

            List(selection: $selection) {
                ForEach($store.settings.glossary) { $entry in
                    HStack(spacing: 8) {
                        TextField("Term", text: $entry.canonical)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        TextField("Often heard as (comma separated)", text: Binding(
                            get: { entry.heardAs.joined(separator: ", ") },
                            set: { entry.heardAs = $0.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty } }))
                            .textFieldStyle(.roundedBorder)
                    }
                    .tag(entry.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack {
                Button {
                    store.settings.glossary.append(GlossaryEntry(canonical: ""))
                } label: { Image(systemName: "plus") }

                Button {
                    store.settings.glossary.removeAll { selection.contains($0.id) }
                    selection.removeAll()
                } label: { Image(systemName: "minus") }
                .disabled(selection.isEmpty)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .padding(.top, 12)
    }
}

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        VStack(spacing: 0) {
            if controller.history.isEmpty {
                Spacer()
                Text("Nothing dictated yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(controller.history) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.date, format: .dateTime.hour().minute().day().month())
                                .font(.caption).foregroundStyle(.secondary)
                            if let app = entry.app {
                                Text("· \(app)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            CopyButton(text: entry.output).font(.caption)
                        }
                        Text(entry.output).font(.system(size: 12))
                        if entry.transcript != entry.output {
                            Text(entry.transcript)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Shared components

/// Not private: also used by `OnboardingView`.
struct SecretField: View {
    let title: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack {
            if revealed {
                TextField(title, text: $text)
            } else {
                SecureField(title, text: $text)
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Edits a `[String]` as one-item-per-line text. Blank lines are preserved while
/// typing and filtered out where the list is actually used.
private struct LineListEditor: View {
    @Binding var lines: [String]
    var height: CGFloat = 70

    var body: some View {
        TextEditor(text: Binding(
            get: { lines.joined(separator: "\n") },
            set: { lines = $0.components(separatedBy: "\n") }))
            .font(.system(size: 12, design: .monospaced))
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
    }
}
