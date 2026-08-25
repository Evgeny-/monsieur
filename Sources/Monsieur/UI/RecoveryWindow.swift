import AppKit
import SwiftUI

/// Shown when the dictated text could not be typed anywhere -- no Accessibility
/// permission, or nothing focused that accepts text.
///
/// Deliberately does not copy anything on your behalf. Quietly overwriting
/// whatever you had on the clipboard is a side effect nobody asked for; the
/// button here puts it there only if you want it.
@MainActor
final class RecoveryWindowController {

    static let shared = RecoveryWindowController()

    private var window: NSWindow?

    private init() {}

    func present(text: String, reason: String) {
        let view = RecoveryView(text: text, reason: reason) { [weak self] in
            self?.window?.close()
        }

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Dictated text"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct RecoveryView: View {
    let text: String
    let reason: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.insert")
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Selectable rather than a TextEditor: this is a result to take
            // away, not a draft to edit, and an editable field invites you to
            // change text that is already on the clipboard unchanged.
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            HStack {
                Text("Your clipboard has not been touched.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Close", action: onClose)
                CopyButton(text: text, title: "Copy", style: .prominent)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 260)
    }
}
