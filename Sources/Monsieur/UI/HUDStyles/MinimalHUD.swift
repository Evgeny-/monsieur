import SwiftUI

/// "Just the words, no chrome": no title line, no icon, no meter. The
/// transcript is the entire design, and the only status indicator is one
/// small dot -- so there is nothing left for the eye to read except the
/// words themselves.
///
/// The panel is a fixed 420x48 (see `HUDStyleID.preferredSize`), which this
/// view fills exactly instead of sizing its background to the current line
/// of text. An earlier version hugged its content so a short utterance read
/// as a tight badge -- but that meant the capsule grew and shrank by a few
/// pixels on every transcript update, which reads as a constant shiver, not
/// a badge. Filling the fixed frame trades that jitter for a little empty
/// space after short utterances, which is the right trade: a panel that
/// visibly vibrates as you talk is worse than one with room to spare.
struct MinimalHUD: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 9) {
            phaseDot
            content
                // Text is laid out on its full line box, top of the ascenders
                // to bottom of the descenders, but the eye centres on the band
                // of lowercase letters -- which measures 1.15pt lower. Nudged
                // back up so it looks centred rather than merely being so.
                .offset(y: -1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: 420, height: 44, alignment: .leading)
        // `.frame` above fixes this view's own size to 420x48 regardless of
        // the HStack's natural size, so the background and clip that follow
        // paint that fixed size, not a size that tracks the transcript --
        // that ordering is what actually kills the jitter described above.
        //
        // `.background(_:in:)` only accepts a ShapeStyle, and a live
        // NSVisualEffectView isn't one, so the paint step has to go through
        // the view-builder overload instead -- which, unlike the ShapeStyle
        // one, does not clip to the shape for you, hence the explicit
        // `.clipShape` afterwards.
        .background { VisualEffectBackground() }
        .clipShape(shape)
        // A lit hairline along the edge. Without it the capsule ends in
        // nothing and the boundary reads as a dark outline rather than as the
        // rim of a piece of glass; brighter at the top, as light would be.
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1))
    }

    private var shape: Capsule { Capsule(style: .continuous) }

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = model.phase {
            Text(message)
                .font(transcriptFont)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if case .working(let label) = model.phase {
            // Replacing the transcript rather than covering it: by this point
            // the transcript is final and about to be swapped for the polished
            // version anyway, so the status is the only live information left,
            // and nothing shows through from underneath.
            Text(label)
                .font(transcriptFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            // TranscriptText already draws committed words solid and the
            // in-flight ones dimmed, which is the one distinction this
            // design is not allowed to drop.
            TranscriptText(model: model, font: transcriptFont)
                .lineLimit(1)
                // Head truncation keeps the newest words on screen as a
                // line fills up -- for a live transcript the tail matters
                // more than the words that scrolled by first.
                .truncationMode(.head)
        }
    }

    /// The only phase indicator in this design: colour says which phase it's
    /// in, and while listening a halo plus a scale bump ride `model.level`
    /// directly. The previous version ran a fixed `repeatForever` breathing
    /// loop here regardless of input, so a loud word and dead silence looked
    /// identical -- driving straight off the model instead means the dot can
    /// only look "alive" when there is actually signal to show.
    private var phaseDot: some View {
        ZStack {
            if case .working = model.phase {
                // A spinner is the one piece of chrome worth the exception:
                // it is the only shape that unambiguously means "still going".
                ProgressView().controlSize(.small)
            } else {
                if model.phase == .listening {
                    Circle()
                        .fill(dotColor.opacity(haloOpacity))
                        .frame(width: haloDiameter, height: haloDiameter)
                        .blur(radius: 2)
                }
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .scaleEffect(coreScale)
            }
        }
        // Fixed no matter what the halo/scale below are doing, so their
        // reaction to level is purely decorative overflow that never
        // reaches the HStack's layout -- an animated child that resizes its
        // own layout footprint would reintroduce exactly the jitter the
        // frame above exists to prevent.
        .frame(width: 22, height: 22)
        .animation(.easeOut(duration: 0.08), value: model.level)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    private var levelAmount: CGFloat { CGFloat(min(max(model.level, 0), 1)) }

    /// 9pt at silence up to 22pt at full input -- large enough against a 6pt
    /// core dot to read as a clear reaction rather than a rounding error.
    private var haloDiameter: CGFloat { 9 + levelAmount * 13 }
    private var haloOpacity: Double { 0.18 + Double(levelAmount) * 0.45 }

    /// Silence still sits below 1x, so the moment speech starts the jump
    /// toward full scale is visible rather than starting from a size that
    /// already looks the same as "not listening".
    private var coreScale: CGFloat {
        guard model.phase == .listening else { return 1 }
        return 0.82 + levelAmount * 0.6
    }

    private var dotColor: Color {
        switch model.phase {
        case .listening: return .accentColor
        case .working: return .secondary
        case .failed: return .orange
        case .done: return .green
        }
    }

    private var transcriptFont: Font { .system(size: 13, weight: .medium) }
}
