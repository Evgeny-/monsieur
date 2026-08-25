import SwiftUI

/// A copy button that says so. Without the confirmation there is no way to tell
/// a successful copy from a dead button -- the clipboard gives no feedback of
/// its own, and the text you copied looks identical either way.
struct CopyButton: View {
    let text: String
    var title: String = "Copy"
    var style: Style = .link

    enum Style { case link, bordered, prominent }

    @State private var copied = false

    @ViewBuilder
    var body: some View {
        // Branch on the finished button rather than on the style value: a
        // ViewBuilder can pick between Views, but not between ButtonStyles.
        switch style {
        case .link: button.buttonStyle(.borderless)
        case .bordered: button.buttonStyle(.bordered)
        case .prominent: button.buttonStyle(.borderedProminent)
        }
    }

    private var button: some View {
        Button {
            TextInserter.copyToClipboard(text)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeIn(duration: 0.25)) { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : title,
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(copied ? Color.green : Color.accentColor)
                // Fixed width so the label swapping does not shuffle the layout
                // around it every time you press it.
                .frame(minWidth: 68, alignment: .leading)
        }
        .disabled(text.isEmpty)
    }
}
