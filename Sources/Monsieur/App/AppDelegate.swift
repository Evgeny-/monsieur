import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private let controller = DictationController.shared
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(controller: controller)
        RemoteControl.listen(controller: controller)

        applyHotkeys(SettingsStore.shared.settings)
        // The emitted value has to be used rather than re-read from the store:
        // @Published fires in willSet, so `SettingsStore.shared.settings` is
        // still the *old* settings while this closure runs.
        SettingsStore.shared.$settings
            .removeDuplicates { a, b in
                a.hotkey == b.hotkey && a.rawHotkey == b.rawHotkey
                    && a.hotkeyMode == b.hotkeyMode
            }
            .dropFirst()
            .sink { [weak self] settings in self?.applyHotkeys(settings) }
            .store(in: &cancellables)

        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.updateHUD(for: state) }
            .store(in: &cancellables)

        if !SettingsStore.shared.settings.hasCompletedSetup {
            OnboardingWindowController.shared.present()
        }
        // Reported at launch because it is the one permission the app cannot
        // work without, and because a grant surviving a rebuild is the whole
        // reason the build signs with a stable certificate.
        Log.app.info("accessibility granted: \(TextInserter.hasAccessibilityPermission, privacy: .public)")
        Log.app.info("Monsieur ready")
    }

    // MARK: - Hotkeys

    private func applyHotkeys(_ settings: Settings) {
        var bindings: [(hotkey: Hotkey, onPress: () -> Void, onRelease: () -> Void)] = []

        if let main = Hotkey.parse(settings.hotkey) {
            bindings.append(makeBinding(main, mode: settings.hotkeyMode, bypassLLM: false))
        } else {
            Log.hotkey.error("cannot parse hotkey '\(settings.hotkey, privacy: .public)'")
        }
        if !settings.rawHotkey.isEmpty, let raw = Hotkey.parse(settings.rawHotkey) {
            bindings.append(makeBinding(raw, mode: settings.hotkeyMode, bypassLLM: true))
        }
        HotkeyManager.shared.setBindings(bindings)
    }

    private func makeBinding(_ hotkey: Hotkey, mode: HotkeyMode, bypassLLM: Bool)
        -> (hotkey: Hotkey, onPress: () -> Void, onRelease: () -> Void) {
        switch mode {
        case .toggle:
            return (hotkey,
                    { [weak self] in self?.controller.toggle(bypassLLM: bypassLLM) },
                    {})
        case .pushToTalk:
            return (hotkey,
                    { [weak self] in self?.controller.start(bypassLLM: bypassLLM) },
                    { [weak self] in self?.controller.stop() })
        }
    }

    // MARK: - HUD

    private func updateHUD(for state: DictationController.State) {
        guard SettingsStore.shared.settings.showHUD else {
            HUDController.shared.hide()
            return
        }
        switch state {
        case .recording, .working, .failed:
            HUDController.shared.show(controller: controller,
                                      settings: SettingsStore.shared.settings)
        case .idle:
            // Gone at once. The lingering "done" state was showing an empty
            // overlay with a tick in it for most of a second after the text had
            // already landed -- the transcript is cleared by then, so there was
            // nothing in it to read. The text appearing where you were typing
            // is the confirmation; a pill announcing the same thing afterwards
            // just looks like something failed to close.
            HUDController.shared.hide()
        }
    }
}
