import AppKit
import SwiftUI

/// "Frosted": the heaviest-glass HUD design. A real `NSVisualEffectView`
/// blur of whatever is behind the window, pushed further with vibrancy, and
/// two restrained gradient flourishes -- a surface sheen and a bright-top
/// edge -- so it still reads as glass rather than a flat tinted rectangle.
///
/// This is a deliberate cut-down from the first version. At 440x88 there was
/// enough panel to carry a sheen, an inset highlight, *and* a separate
/// border, plus a two-line layout; shrunk to 400x60 (roughly a third less
/// area) that much scaffolding just read as cramped and busy -- "beautiful
/// but bulky, kind of scary" was the actual feedback. The fix is fewer
/// things at this size, not the same things smaller: one line of text, one
/// badge, and the sheen and border merged down to the two flourishes below.
///
/// Liquid Glass (`.glassEffect()`, `NSGlassEffectView`) is not used at all,
/// not even behind `if #available(macOS 26, *)`: it compiles against the
/// macOS 26 SDK but silently fails to render on this machine's 15.7.4
/// runtime, and there is nothing left to preview or ship on the branch that
/// actually executes today. `VisualEffectBackground` is the one primitive
/// here guaranteed to draw on every macOS version this app targets.
struct FrostedHUD: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            indicator
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 400, height: 60, alignment: .leading)
        .background(glass)
        .overlay(edge)
        .clipShape(shape)
    }

    // MARK: - Text

    /// One line, full stop -- there is no room at 60pt tall for the old
    /// separate status-line-plus-transcript layout. A working label (e.g.
    /// "Rewriting…") says more in that one line than the frozen transcript
    /// underneath it would, since the transcript stops changing the moment
    /// listening ends; failure keeps its own message. Listening and done
    /// fall through to the transcript, which is the actual point of the HUD
    /// the rest of the time.
    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .failed(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case .working(let label):
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        default:
            TranscriptText(model: model, font: .system(size: 13))
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    // MARK: - Indicator

    @ViewBuilder
    private var indicator: some View {
        ZStack {
            switch model.phase {
            case .listening:
                LevelIndicator(level: model.level, tint: indicatorTint)
            case .working:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 36, height: 36)
        .animation(.easeOut(duration: 0.09), value: model.level)
    }

    private var indicatorTint: Color {
        switch model.phase {
        case .listening, .working: return .accentColor
        case .failed: return .orange
        case .done: return .green
        }
    }

    /// The backing wash behind the indicator icon. Fixed and faint for every
    /// other phase, same as before -- but while listening it tracks the mic
    /// level too, so the badge itself visibly brightens on top of
    /// `LevelIndicator`'s own reaction instead of sitting there static while
    /// only the small glow inside it moves.
    // MARK: - Glass

    /// Reduced from 22: at a 60pt-tall panel that radius is close to half
    /// the height, which reads as a lozenge/capsule rather than a rounded
    /// rectangle. 16 keeps the same family resemblance to the other designs'
    /// corner treatment without going full pill.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    /// The blur plus the surface sheen, flattened into one layer with
    /// `compositingGroup` before it joins the rest of the view: without
    /// that, the sheen's `.overlay` blend would reach past the material and
    /// mix with whatever sits behind this transparent window instead of it.
    ///
    /// Explored the material alternatives before settling here. `.popover`,
    /// `.sidebar`, `.menu`, and `.underWindowBackground` are meant to sit
    /// inside a window and track that window's light/dark appearance --
    /// wrong for a borderless overlay with no app of its own. `.hudWindow`
    /// renders a fixed, heavily vibrant dark glass that reads the same, and
    /// stays legible, no matter what's underneath or which appearance the
    /// system is in -- which is also what satisfies "works in both
    /// appearances" for free: there is no appearance branch to get wrong.
    /// `emphasized` pushes the vibrancy further still, which is what still
    /// marks this design out as the heaviest glass of the set even after
    /// the decoration below was cut back.
    private var glass: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blending: .behindWindow, emphasized: true)
            sheen
        }
        .compositingGroup()
        .clipShape(shape)
    }

    /// Kept from the original: a top-down wash blended with `.overlay` so
    /// the glass looks lit from above rather than evenly tinted. Trimmed to
    /// two stops with a lower peak opacity -- the old three-stop version
    /// (with a bottom shadow tint) read as a heavy band once the panel
    /// shrank, which was a direct contributor to "bulky".
    private var sheen: some View {
        LinearGradient(
            colors: [.white.opacity(0.16), .white.opacity(0)],
            startPoint: .top, endPoint: .bottom)
        .blendMode(.overlay)
    }

    /// The other survivor, and the only stroke drawn now. The previous
    /// version drew an inset highlight *and* a full border a point apart --
    /// at this height those two blurred into a fuzzy double outline instead
    /// of reading as separate effects. One gradient border, bright at the
    /// top and faint at the bottom, carries the same "catching light from
    /// above" cue on its own.
    private var edge: some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [.white.opacity(0.5), .white.opacity(0.1)],
                startPoint: .top, endPoint: .bottom),
            lineWidth: 1)
    }
}

/// The mic-level readout -- and, per feedback, the whole reason this HUD
/// exists during dictation, so it has to be unmistakable rather than
/// tasteful-to-a-fault. The previous version moved a blurred halo between
/// 12 and 26pt around a *fixed* 8pt dot at fixed opacity, which is exactly
/// why it tested as "barely noticeable": only one of its three layers ever
/// actually changed. This one reacts on every axis at once -- halo size,
/// halo brightness, and core size, on top of the badge behind it also
/// brightening -- so the swing between silence and speech is big enough to
/// catch in peripheral vision, not just on close inspection. Still a single
/// glow rather than a bar meter: against a heavy frosted blur that is what
/// reads as "the glass lit from within" instead of competing with it.
private struct LevelIndicator: View {
    var level: Float
    var tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.3 + clamped * 0.35))
                .frame(width: haloDiameter, height: haloDiameter)
                .blur(radius: 5)
            Circle()
                .fill(tint)
                .frame(width: coreDiameter, height: coreDiameter)
        }
        .animation(.easeOut(duration: 0.09), value: level)
    }

    private var clamped: CGFloat { CGFloat(min(max(level, 0), 1)) }
    private var haloDiameter: CGFloat { 16 + clamped * 20 }
    private var coreDiameter: CGFloat { 10 + clamped * 16 }
}
