import AppKit
import SwiftUI

/// Shown on first launch, and reachable again from the menu bar (Run Setup…).
///
/// The point of this window is not just to collect keys -- it is the first
/// thing a clone of this repo shows you, so it doubles as an explanation of
/// the app's shape: a required transcription stage, and an optional
/// rewriting stage on top of it.
@MainActor
final class OnboardingWindowController {

    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    private init() {}

    func present() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                // Resizable, unlike the Settings window: this one's content
                // changes shape as sections appear (an OpenAI key field, a
                // target-language field), and a fixed height was a guess.
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Welcome to Monsieur"
            window.contentViewController = NSHostingController(rootView: OnboardingView())
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if let frame = self?.window?.frame {
                Log.app.info("onboarding window \(Int(frame.width))x\(Int(frame.height))")
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

struct OnboardingView: View {
    @ObservedObject var store = SettingsStore.shared

    /// nil means "not chosen yet in this run of the wizard" -- distinct from
    /// `Settings.sttLanguage` being nil, which means auto-detect. Seeding the
    /// picker straight from settings would show Auto-detect pre-selected
    /// before the user ever touched it, which is exactly the silent default
    /// this screen exists to avoid. Seeded once, from `onAppear`, below.
    @State private var chosenLanguageID: String?
    @State private var hasSeededLanguage = false
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                transcriptionSection
                languageSection
                rewritingSection
                importSection
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 560, height: 620)
        .onAppear {
            guard !hasSeededLanguage else { return }
            hasSeededLanguage = true
            // Only trust settings on disk if a previous run of this wizard
            // actually wrote them -- see the property comment above.
            if store.settings.hasCompletedSetup {
                chosenLanguageID = store.settings.languagePreset
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Monsieur").font(.title2).bold()
            Text("Press a hotkey, talk, and the text appears at your cursor.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 8, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 1. Transcription (required)

    private var sttKeyProvided: Bool {
        store.settings.sttProvider.isConfigured(store.settings)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, required: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(required ? "required" : "optional")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    (required ? Color.accentColor : Color.secondary).opacity(0.18),
                    in: Capsule())
                .foregroundStyle(required ? Color.accentColor : Color.secondary)
        }
    }

    private var transcriptionSection: some View {
        Section { transcriptionFields } header: { sectionHeader("Transcription", required: true) }
    }

    @ViewBuilder
    private var transcriptionFields: some View {
            Picker("Service", selection: $store.settings.sttProvider) {
                ForEach(STTProvider.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            switch store.settings.sttProvider {
            case .elevenlabs:
                SecretField(title: "ElevenLabs API key", text: $store.settings.elevenLabsAPIKey)
            case .openai:
                SecretField(title: "OpenAI API key", text: $store.settings.openAIAPIKey)
            }
        }

    // MARK: - 2. Spoken language (required)

    private var selectedPreset: LanguagePreset? {
        chosenLanguageID.flatMap { id in LanguagePreset.all.first { $0.id == id } }
    }

    /// Picking a language here always applies immediately, unlike the
    /// equivalent picker in Settings: nothing has been customised yet at
    /// this point in the flow, so there is nothing to protect by asking.
    private var languageBinding: Binding<String?> {
        Binding(
            get: { chosenLanguageID },
            set: { newID in
                chosenLanguageID = newID
                guard let newID, let preset = LanguagePreset.all.first(where: { $0.id == newID })
                else { return }
                store.settings = preset.applied(to: store.settings, replacePhrases: true)
            })
    }

    private var languageSection: some View {
        Section { languageFields } header: { sectionHeader("Language", required: true) }
    }

    @ViewBuilder
    private var languageFields: some View {
            Picker("I speak", selection: languageBinding) {
                Text("Choose…").tag(nil as String?)
                ForEach(LanguagePreset.all) { preset in
                    Text(preset.displayName).tag(preset.id as String?)
                }
            }
            Text("Only picks the words that stop a recording and introduce a spoken instruction. Speech is understood in any language either way.")
                .font(.caption2).foregroundStyle(.secondary)
        }

    // MARK: - 3. Rewriting (optional)

    private var rewritingReady: Bool {
        store.settings.llmProvider == .none || store.settings.llmEnabled
    }

    private var rewritingSection: some View {
        Section { rewritingFields } header: { sectionHeader("Rewriting", required: false) }
    }

    @ViewBuilder
    private var rewritingFields: some View {
            Picker("Service", selection: $store.settings.llmProvider) {
                ForEach(LLMProvider.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            switch store.settings.llmProvider {
            case .none:
                EmptyView()
            case .openai:
                // One OpenAI key covers both stages. Presenting the same field
                // twice reads as being asked for a second key.
                if store.settings.sttProvider == .openai,
                   !store.settings.openAIAPIKey.isEmpty {
                    Label("Using the OpenAI key from above.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    SecretField(title: "OpenAI API key", text: $store.settings.openAIAPIKey)
                }
                TargetLanguagePicker(language: $store.settings.targetLanguage)
            case .anthropic:
                SecretField(title: "Anthropic API key", text: $store.settings.anthropicAPIKey)
                TargetLanguagePicker(language: $store.settings.targetLanguage)
            case .openrouter:
                SecretField(title: "OpenRouter API key", text: $store.settings.openRouterAPIKey)
                TargetLanguagePicker(language: $store.settings.targetLanguage)
            }
        }

    // MARK: - Advanced

    /// Tucked away: most people setting this up have an API key on a web page,
    /// not a dotenv file sitting on disk, and offering it up front only invites
    /// the question of what it is.
    private var importSection: some View {
        Section {
            // Bound to explicit state with a tappable label: the stock
            // disclosure only responds to a hit on the little triangle, which
            // is a needlessly small target for a row that reads as clickable.
            DisclosureGroup(isExpanded: $showAdvanced) {
                Button("Import keys from a .env file…") { importEnvFile(into: store) }
            } label: {
                Text("Advanced")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showAdvanced.toggle() } }
            }
        }
    }

    // MARK: - Footer

    private var canFinish: Bool {
        sttKeyProvided && chosenLanguageID != nil && rewritingReady
    }

    private var missingRequirements: String {
        var missing: [String] = []
        if !sttKeyProvided { missing.append("a transcription API key") }
        if chosenLanguageID == nil { missing.append("a spoken language") }
        if !rewritingReady { missing.append("a rewriting API key (or Off)") }
        return "Still needed: " + missing.joined(separator: ", ") + "."
    }

    private var footer: some View {
        HStack {
            if canFinish {
                Text("Everything here stays editable later in Settings.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Text(missingRequirements)
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button("Get Started") {
                store.settings.hasCompletedSetup = true
                OnboardingWindowController.shared.close()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canFinish)
        }
        .padding(16)
    }
}
