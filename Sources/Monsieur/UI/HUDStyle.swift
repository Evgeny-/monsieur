import AppKit
import SwiftUI

/// Everything a HUD design is allowed to draw, decoupled from the controller.
///
/// Designs receive this as a plain value rather than observing the controller,
/// so each one is a pure view: easy to write, easy to swap, and impossible to
/// accidentally couple to app state.
struct HUDModel: Equatable {

    enum Phase: Equatable {
        case listening
        /// Post-recording work. The payload is the user-facing label, e.g.
        /// "Transcribing…", "Rewriting…", "Inserting…".
        case working(String)
        case failed(String)
        case done
    }

    var phase: Phase = .listening

    /// Segments the recogniser has finalised. These will not change again.
    var committedText: String = ""

    /// The segment still in flight. The recogniser revises this as it listens,
    /// so a design that distinguishes it -- grey, dimmed, italic -- is telling
    /// the truth about which words are settled.
    var partialText: String = ""

    /// Input level, 0...1, for meters and waveforms.
    var level: Float = 0

    /// Both parts joined, for designs that do not distinguish them.
    var fullText: String {
        [committedText, partialText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var isEmpty: Bool { committedText.isEmpty && partialText.isEmpty }

    /// Representative content for previewing a design from the menu: enough
    /// committed text to show wrapping, plus an unsettled tail so the
    /// committed-versus-partial distinction is actually visible.
    /// French rather than the author's own language: this ships publicly, and
    /// the sample doubles as the clearest statement of what the app is for --
    /// speak one language, get another.
    static let sample = HUDModel(
        phase: .listening,
        committedText: "Peux-tu vérifier les journaux de production",
        partialText: "et me dire ce qui a échoué pendant",
        level: 0.5)
}

/// Where the overlay sits on screen.
///
/// Configurable because there is no safe default: wherever it goes it covers
/// something, and only the person looking at the screen knows what they can
/// afford to lose sight of.
enum HUDPosition: String, Codable, CaseIterable {
    case topLeft, topCenter, topRight
    case bottomLeft, bottomCenter, bottomRight

    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom"
        case .bottomRight: return "Bottom right"
        }
    }

    /// Inset from the screen's usable edges.
    private var margin: CGFloat { 24 }

    func origin(for size: CGSize, in visible: CGRect) -> CGPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft: x = visible.minX + margin
        case .topCenter, .bottomCenter: x = visible.midX - size.width / 2
        case .topRight, .bottomRight: x = visible.maxX - size.width - margin
        }
        let y: CGFloat
        switch self {
        case .topLeft, .topCenter, .topRight: y = visible.maxY - size.height - margin
        case .bottomLeft, .bottomCenter, .bottomRight: y = visible.minY + margin
        }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Shared building blocks

/// `NSVisualEffectView` bridged into SwiftUI.
///
/// Liquid Glass (`.glassEffect()`, `NSGlassEffectView`) is macOS 26 only, so on
/// Sequoia this is the real frosted-glass primitive: a live blur of what is
/// behind the window, which `Color.opacity` cannot imitate.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = emphasized
    }
}

/// Committed words solid, in-flight words dimmed. Shared so every design that
/// wants this behaviour renders it identically.
struct TranscriptText: View {
    let model: HUDModel
    var font: Font = .system(size: 13)
    var placeholder: String = "Speak now…"

    var body: some View {
        Group {
            if model.isEmpty {
                Text(model.phase == .listening ? placeholder : " ")
                    .foregroundStyle(.tertiary)
            } else {
                Text(model.committedText)
                    .foregroundStyle(.primary)
                + Text(model.committedText.isEmpty ? "" : " ")
                + Text(model.partialText)
                    .foregroundStyle(.secondary)
            }
        }
        .font(font)
    }
}
