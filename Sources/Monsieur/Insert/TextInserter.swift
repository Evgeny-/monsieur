import AppKit
import ApplicationServices

/// Puts the finished text into whatever text field the user was in.
///
/// Two strategies, and the default is deliberately the cruder one:
///
/// - **Clipboard + synthesised Cmd-V** works in essentially everything,
///   including the Electron apps that matter here (Claude Desktop, VS Code,
///   Slack). The clipboard is saved and restored around it.
/// - **Accessibility API** (`kAXSelectedTextAttribute`) is cleaner and leaves
///   the clipboard untouched, but it silently no-ops on any element that is not
///   a real AX text field -- and it reports success while doing so -- which is
///   why it is not the default.
@MainActor
enum TextInserter {

    // MARK: - Permission

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Insertion

    enum Result {
        case inserted
        case copiedOnly
        case failed(String)
    }

    /// Whether the thing with keyboard focus looks like it can take text.
    ///
    /// Returns `nil` whenever we cannot be sure, which is most of the time.
    /// Only a definite `false` suppresses the paste, because the two failure
    /// modes are wildly asymmetric: pasting into nothing costs the user one
    /// dialog, while refusing to paste into a field that would have worked
    /// breaks the app for that application entirely.
    ///
    /// The first version of this treated `kAXErrorNoValue` as "no target" and
    /// broke exactly that way. Applications that report no focused element --
    /// Electron and web content especially -- still accept a paste perfectly
    /// well.
    static func focusedElementAcceptsText() -> Bool? {
        // Our own windows are never a destination. With Settings or the setup
        // window in front, the system-wide query returns *their* focused
        // field, so the dictation would be typed into the app that produced
        // it -- an API key field, in the worst case -- and reported as a
        // success. Nothing to paste into is exactly what this is.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == Bundle.main.bundleIdentifier {
            Log.insert.info("frontmost app is Monsieur itself; refusing to paste")
            return false
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused)

        guard status == .success, let value = focused,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Log.insert.info("focus probe [\(app, privacy: .public)]: no element (AXError \(status.rawValue)) — pasting anyway")
            return nil
        }
        let element = value as! AXUIElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleString = (role as? String) ?? ""
        var range: CFTypeRef?
        let hasRange = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &range) == .success

        let verdict: Bool?
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(roleString) || hasRange {
            // A selected-text range is the strongest available signal, and it is
            // what web views and Electron expose once focused.
            verdict = true
        } else if Self.definitelyNotText.contains(roleString) {
            verdict = false
        } else {
            verdict = nil
        }

        Log.insert.info("focus probe [\(app, privacy: .public)]: role=\(roleString, privacy: .public) range=\(hasRange) -> \(verdict.map(String.init) ?? "unknown", privacy: .public)")
        return verdict
    }

    /// Roles that cannot possibly receive typed text. Kept deliberately short:
    /// every addition is a new way to wrongly refuse a working paste.
    private static let definitelyNotText: Set<String> = [
        kAXButtonRole, kAXImageRole, kAXMenuItemRole, kAXMenuBarItemRole,
        kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole, kAXProgressIndicatorRole,
    ]

    static func insert(_ text: String, settings: Settings) async -> Result {
        guard !text.isEmpty else { return .failed("Nothing to insert.") }

        if settings.copyOnly {
            copyToClipboard(text)
            return .copiedOnly
        }
        guard hasAccessibilityPermission else {
            return .failed("Monsieur does not have Accessibility permission, so it cannot type into other apps.")
        }

        if focusedElementAcceptsText() == false {
            return .failed("Nothing that accepts text was focused, so there was nowhere to type.")
        }

        if !settings.pasteViaClipboard, insertViaAccessibility(text) {
            return .inserted
        }
        await pasteViaClipboard(text)
        return .inserted
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Clipboard strategy

    private static func pasteViaClipboard(_ text: String) async {
        let saved = snapshotPasteboard()

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // The hotkey's own modifiers are probably still physically down. Sending
        // Cmd-V while Ctrl and Option are held produces Ctrl-Option-Cmd-V, which
        // is some other app's shortcut. Wait for the user to let go.
        await waitForModifiersToClear()
        sendCommandV()

        // Give the target app time to actually read the pasteboard.
        try? await Task.sleep(for: .milliseconds(500))
        restorePasteboard(saved)
    }

    private static func waitForModifiersToClear(timeout: TimeInterval = 1.0) async {
        let interesting: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(interesting).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Log.insert.info("modifiers still held after \(timeout, privacy: .public)s; pasting anyway")
    }

    private static func sendCommandV() {
        let vKey: CGKeyCode = 0x09   // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Stop the physical keyboard from injecting flags into our synthetic events.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Accessibility strategy

    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused
        else { return false }

        // CFGetTypeID guards against the attribute being something other than an
        // AXUIElement, which would otherwise crash on the force cast.
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let axElement = element as! AXUIElement

        // Only attempt this on elements that actually claim to hold text --
        // setting kAXSelectedText on anything else returns .success and does
        // nothing at all.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        let roleString = (role as? String) ?? ""
        let textRoles = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSearchFieldSubrole,
        ]
        guard textRoles.contains(roleString) else { return false }

        let status = AXUIElementSetAttributeValue(
            axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return status == .success
    }

    // MARK: - Pasteboard preservation

    private static func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        NSPasteboard.general.pasteboardItems?.map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        } ?? []
    }

    private static func restorePasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}
