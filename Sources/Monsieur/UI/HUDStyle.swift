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

/// The available HUD designs. Adding a case here and a branch in `makeView`
/// is all it takes to add another; the menu switcher is generated from
/// `allCases`.
enum HUDStyleID: String, Codable, CaseIterable {
    case minimal
    case classic
    case frosted
    case teleprompter
    case waveform

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .minimal: return "Minimal"
        case .frosted: return "Frosted"
        case .teleprompter: return "Teleprompter"
        case .waveform: return "Waveform"
        }
    }

    var detail: String {
        switch self {
        case .classic: return "Pill with a status line and a level meter"
        case .minimal: return "Just the words, no chrome"
        case .frosted: return "Heavier translucency and vibrancy"
        case .teleprompter: return "Two lines that scroll upward as you speak"
        case .waveform: return "Wide, low bar driven by the input level"
        }
    }

    /// The panel is sized to this, and designs should fill it exactly rather
    /// than hugging their content: a container that resizes as words arrive
    /// jitters a few pixels on every update, which is far more distracting
    /// than a little empty space.
    var preferredSize: CGSize {
        switch self {
        case .classic: return CGSize(width: 420, height: 76)
        case .minimal: return CGSize(width: 420, height: 44)
        case .frosted: return CGSize(width: 400, height: 60)
        case .teleprompter: return CGSize(width: 460, height: 51)
        case .waveform: return CGSize(width: 380, height: 56)
        }
    }

    @ViewBuilder
    func makeView(model: HUDModel) -> some View {
        switch self {
        case .classic: ClassicHUD(model: model)
        case .minimal: MinimalHUD(model: model)
        case .frosted: FrostedHUD(model: model)
        case .teleprompter: TeleprompterHUD(model: model)
        case .waveform: WaveformHUD(model: model)
        }
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
