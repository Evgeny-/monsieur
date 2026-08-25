import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let controller: DictationController
    private var cancellables: Set<AnyCancellable> = []
    private var settingsWindow: NSWindow?

    init(controller: DictationController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Without an autosave name, a position you set by ⌘-dragging the icon is
        // not reliably remembered across launches.
        statusItem.autosaveName = "Monsieur"
        buildMenu()
        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)
        // History changing has to repaint too, or Copy stays greyed out until
        // some unrelated state change happens to refresh the menu.
        controller.$history
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.render(self.controller.state)
            }
            .store(in: &cancellables)
        SettingsStore.shared.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.applyLabel(settings.showMenuBarLabel)
                self?.refreshHotkeyTitles(settings)
            }
            .store(in: &cancellables)
        render(.idle)
        reportPlacement()
        announce()
    }

    // MARK: - Findability

    /// Flashes the app's name beside the icon for a few seconds at launch.
    ///
    /// A monochrome glyph dropped into the leftmost slot of a crowded menu bar
    /// -- right against the notch on these displays -- is genuinely hard to
    /// locate the first time. A few seconds of text solves that once.
    private func announce() {
        guard !SettingsStore.shared.settings.showMenuBarLabel else { return }
        statusItem.button?.title = " Monsieur"
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard !SettingsStore.shared.settings.showMenuBarLabel else { return }
            statusItem.button?.title = ""
        }
    }

    private func applyLabel(_ show: Bool) {
        statusItem.button?.title = show ? " Monsieur" : ""
    }

    /// A menu bar that has run out of room drops status items silently -- and on
    /// a notched display it runs out sooner than the screen width suggests. Log
    /// where we actually landed so "I can't find the icon" is answerable.
    private func reportPlacement() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard let button = self.statusItem.button else {
                Log.app.error("status item has no button — nothing will be drawn")
                return
            }
            let visible = self.statusItem.isVisible
            guard let window = button.window else {
                Log.app.error("status item is not in a window (visible=\(visible)) — the menu bar is full")
                return
            }
            let frame = window.frame
            let screen = NSScreen.main?.frame ?? .zero
            let onScreen = frame.maxX > 0 && frame.minX < screen.maxX && frame.width > 0
            Log.app.info(
                "status item: visible=\(visible) frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) screenWidth=\(Int(screen.width)) onScreen=\(onScreen)")
            if !onScreen {
                Log.app.error("status item is off-screen — the menu bar has no room for it")
            }
        }
    }

    // MARK: - Appearance

    private func render(_ state: DictationController.State) {
        guard let button = statusItem.button else { return }
        let name: String
        switch state {
        case .idle: name = "waveform"
        case .recording: name = "waveform.circle.fill"
        case .working: name = "ellipsis.circle"
        case .failed: name = "exclamationmark.triangle"
        }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Monsieur")
        button.image?.isTemplate = true

        if let item = statusItem.menu?.item(withTag: MenuTag.toggle.rawValue) {
            let hotkey = Hotkey.parse(SettingsStore.shared.settings.hotkey)?.display ?? ""
            item.title = (state == .recording ? "Stop dictating" : "Start dictating")
                + (hotkey.isEmpty ? "" : "   \(hotkey)")
        }
        if let item = statusItem.menu?.item(withTag: MenuTag.cancel.rawValue) {
            item.isEnabled = state.isBusy
        }
        if let item = statusItem.menu?.item(withTag: MenuTag.copyLast.rawValue) {
            let last = controller.history.first?.output
            item.isEnabled = last != nil
            // A preview in the tooltip: "last result" means nothing if you
            // cannot remember which dictation that was.
            item.toolTip = last.map { String($0.prefix(200)) }
        }
        if let item = statusItem.menu?.item(withTag: MenuTag.status.rawValue) {
            switch state {
            case .idle: item.title = "Ready"
            case .recording: item.title = "Listening…"
            case .working(let label): item.title = label
            case .failed(let message): item.title = message
            }
        }
    }

    // MARK: - Menu

    private enum MenuTag: Int {
        case toggle = 1, status = 2, verbatim = 3
        case cancel = 5, copyLast = 6
    }

    private func buildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        status.tag = MenuTag.status.rawValue
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Start dictating",
                                action: #selector(toggleDictation), keyEquivalent: "")
        toggle.tag = MenuTag.toggle.rawValue
        toggle.target = self
        menu.addItem(toggle)

        let verbatim = NSMenuItem(title: "Dictate verbatim",
                                  action: #selector(toggleVerbatim), keyEquivalent: "")
        verbatim.tag = MenuTag.verbatim.rawValue
        verbatim.target = self
        menu.addItem(verbatim)

        let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelDictation), keyEquivalent: "")
        cancel.tag = MenuTag.cancel.rawValue
        cancel.target = self
        menu.addItem(cancel)

        let copyLast = NSMenuItem(title: "Copy last result",
                                  action: #selector(copyLastResult), keyEquivalent: "")
        copyLast.tag = MenuTag.copyLast.rawValue
        copyLast.target = self
        menu.addItem(copyLast)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let setup = NSMenuItem(title: "Run Setup…", action: #selector(openOnboarding), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Monsieur",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        // Managed by hand so Cancel greys out when there is nothing to cancel,
        // and Copy when there is nothing to copy.
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshHotkeyTitles(SettingsStore.shared.settings)
    }

    private func refreshHotkeyTitles(_ settings: Settings) {
        if let item = statusItem.menu?.item(withTag: MenuTag.verbatim.rawValue) {
            let hotkey = settings.rawHotkey.isEmpty
                ? "" : (Hotkey.parse(settings.rawHotkey)?.display ?? "")
            item.title = "Dictate verbatim (no rewriting)"
                + (hotkey.isEmpty ? "" : "   \(hotkey)")
        }
        render(controller.state)
    }

    // MARK: - Actions

    @objc private func toggleDictation() { controller.toggle() }
    @objc private func toggleVerbatim() { controller.toggle(bypassLLM: true) }
    @objc private func cancelDictation() { controller.cancel() }

    @objc private func copyLastResult() {
        guard let last = controller.history.first?.output else { return }
        TextInserter.copyToClipboard(last)
    }

    @objc private func openOnboarding() {
        OnboardingWindowController.shared.present()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Monsieur Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
