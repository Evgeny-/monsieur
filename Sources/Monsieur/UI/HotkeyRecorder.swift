import AppKit
import Combine
import SwiftUI

/// A "click it (or focus it), then press the combination" control for a
/// hotkey setting -- the replacement for a text field that expected strings
/// like `ctrl+alt+space`. Not private: `SettingsView` uses it for both the
/// "Dictate" and "Dictate verbatim" rows.
///
/// Reads and writes the same `String` shape `Settings` already persists, so
/// nothing downstream (the JSON on disk, `HotkeyManager` registration in
/// `AppDelegate`) has to change. The one rule this view adds is how it turns
/// a captured `NSEvent` back into that string: it goes through
/// `Hotkey.keyCodes` -- the same table `Hotkey.parse` reads from -- so a key
/// this view is willing to record is always a key `Hotkey.parse` can read
/// back. A captured key with no name in that table is rejected outright and
/// the previous value is left alone.
struct HotkeyRecorder: View {
    let title: String
    @Binding var text: String

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    /// Feedback for a rejected keystroke (no modifier held, or a key with no
    /// name in `Hotkey.keyCodes`). Reset at the start of every new attempt,
    /// so it never outlives the keystroke that caused it.
    @State private var rejection: String?
    /// Non-blocking: the binding is written anyway, this only says what the
    /// consequence will be.
    @State private var caution: String?

    /// A hotkey with no modifier is reserved system-wide the moment it is
    /// registered, so that key stops reaching every other application. For a
    /// function key that is usually exactly what you want. For a letter, digit,
    /// space or return it means you can no longer type it.
    private static func caution(forKeyNamed name: String,
                                modifiers: NSEvent.ModifierFlags) -> String? {
        guard modifiers.isEmpty else { return nil }
        let isFunctionKey = name.first == "f" && name.dropFirst().allSatisfy(\.isNumber)
        if isFunctionKey {
            return "No modifier: \(name.uppercased()) will be taken system-wide."
        }
        return "No modifier: this key will stop working in every other app."
    }
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    recordButton
                    clearButton
                }
                if isRecording {
                    Text(recordingHint)
                        .font(.caption2)
                        // Spelled out as `Color` on both sides of the ternary:
                        // `.secondary` alone is ambiguous between `Color` and
                        // `HierarchicalShapeStyle`, and only `Color` has `.orange`.
                        .foregroundStyle(rejection == nil ? Color.secondary : Color.orange)
                }
            }
            if let caution, !isRecording {
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        // Tabbing to the control is the other documented way in (besides a
        // click) to start recording, per the ask: "I focus it or click a
        // Change button, and I just press the hotkey I want."
        .onChange(of: isFocused) { _, focused in
            if focused {
                startRecording()
            } else {
                stopRecording()
            }
        }
        .onDisappear { stopRecording() }
        // Belt and suspenders alongside `.onDisappear`: the Settings window
        // is created with `isReleasedWhenClosed = false` (see
        // MenuBarController) so it can be reused, which means closing it
        // does not necessarily tear this view down the way a real dismissal
        // would. Losing key window status, on the other hand, always fires --
        // whether the window closed, or the user cmd-tabbed away mid-capture --
        // so it is the more dependable place to give up the monitor.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
    }

    // MARK: - Controls

    private var recordButton: some View {
        // Branch on the whole button rather than a conditional modifier: a
        // ViewBuilder can pick between Views, but `.buttonStyle` needs both
        // branches to share one concrete type, and .bordered /
        // .borderedProminent don't (see CopyButton.swift for the same trick).
        Group {
            if isRecording {
                Button(action: stopRecording) { recordButtonLabel }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            } else {
                Button(action: startRecording) { recordButtonLabel }
                    .buttonStyle(.bordered)
            }
        }
        .focusable()
        .focused($isFocused)
    }

    private var recordButtonLabel: some View {
        Group {
            if isRecording {
                Text(heldSymbols.isEmpty ? "Press a key combination…" : "\(heldSymbols)…")
            } else if let parsed = Hotkey.parse(text) {
                Text(parsed.display)
            } else {
                Text("Click to record a hotkey").foregroundStyle(.secondary)
            }
        }
        // Fixed so the row doesn't shuffle everything else in the Form
        // sideways as the label swaps between "Click to record a hotkey",
        // "Press a key combination…" and a short display string like "⌃⌥Space".
        .frame(minWidth: 170, alignment: .leading)
    }

    @ViewBuilder
    private var clearButton: some View {
        if !isRecording, !text.isEmpty {
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Clear this hotkey")
        }
    }

    private var recordingHint: String {
        guard let rejection else { return "Esc to cancel." }
        return "\(rejection) Esc to cancel."
    }

    /// Live "⌃⌥" feedback for whatever is held so far. There's no `Hotkey`
    /// to call `.display` on yet -- no key has completed the combination --
    /// so the four glyphs are repeated here instead, in the same fixed order
    /// `Hotkey.display` uses (⌃⌥⇧⌘).
    private var heldSymbols: String {
        var s = ""
        if heldModifiers.contains(.control) { s += "⌃" }
        if heldModifiers.contains(.option) { s += "⌥" }
        if heldModifiers.contains(.shift) { s += "⇧" }
        if heldModifiers.contains(.command) { s += "⌘" }
        return s
    }

    // MARK: - Recording

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        rejection = nil
        caution = nil
        heldModifiers = []
        // Returning nil from this handler swallows the event; see `handle`
        // below for why that matters for both cases it's asked to monitor.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        heldModifiers = []
        rejection = nil
        isFocused = false
    }

    /// A swallowed `flagsChanged` keeps a bare modifier from doing anything
    /// else while we're recording (an unmodified Control tap toggles input
    /// sources on some setups); a swallowed `keyDown` is what keeps every
    /// attempt -- valid or not -- from leaking into whatever is focused
    /// underneath, or the app switcher, or the rest of the system.
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            heldModifiers = event.modifierFlags.intersection(Self.hotkeyModifierMask)
            rejection = nil
            caution = nil
            return nil
        case .keyDown:
            return handleKeyDown(event)
        default:
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(Self.hotkeyModifierMask)
        let keyCode = UInt32(event.keyCode)

        // Bare Escape is the documented way out. With a modifier held it's
        // just another combination -- cmd+escape is a perfectly fine hotkey.
        if keyCode == Self.escapeKeyCode, modifiers.isEmpty {
            stopRecording()
            return nil
        }

        // Reverse lookup through the same table `Hotkey.parse` reads from,
        // so this view can never record something that table can't also
        // parse back -- no second table to drift out of sync with it.
        guard let name = Hotkey.keyCodes.first(where: { $0.value == keyCode })?.key else {
            rejection = "That key isn't supported."
            return nil
        }

        caution = Self.caution(forKeyNamed: name, modifiers: modifiers)

        let candidate = (modifierTokens(modifiers) + [name]).joined(separator: "+")
        guard Hotkey.parse(candidate) != nil else {
            // Defensive: unreachable given the two checks above, but a
            // string this view can't parse back is one it must not write.
            rejection = "That key isn't supported."
            return nil
        }

        text = candidate
        stopRecording()
        return nil
    }

    private func modifierTokens(_ flags: NSEvent.ModifierFlags) -> [String] {
        var tokens: [String] = []
        if flags.contains(.control) { tokens.append("ctrl") }
        if flags.contains(.option) { tokens.append("alt") }
        if flags.contains(.shift) { tokens.append("shift") }
        if flags.contains(.command) { tokens.append("cmd") }
        return tokens
    }

    /// The four modifiers a hotkey can actually use -- matches what
    /// `Hotkey.cocoaModifiers` produces exactly. Deliberately narrower than
    /// `.deviceIndependentFlagsMask`: that mask still carries bits like Caps
    /// Lock and the numeric-pad/function flags some keys set, and either of
    /// those being on must not count as "a modifier is held" when this view
    /// decides whether a combination is bare -- otherwise dictating with
    /// Caps Lock on could record a plain, unmodified letter as a system-wide
    /// hotkey, exactly the outcome the bare-key check exists to prevent.
    private static let hotkeyModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// Read from `Hotkey.keyCodes` rather than hard-coded, so this stays
    /// correct if that table ever changes; the `?? 53` only covers the
    /// unreachable case where "escape" is removed from it.
    private static let escapeKeyCode = Hotkey.keyCodes["escape"] ?? 53
}
