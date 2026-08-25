import Foundation
import SwiftUI

/// "Waveform": a wide, low strip where the input level drives a live
/// scrolling waveform, with the transcript riding along underneath it in
/// small type. Per the brief's voice-memo / Siri comparison, the sound is
/// the headline here and the words are just the caption.
///
/// The scroll is paced by a clock (the `.task` loop below), not by
/// incoming level samples. Sampling only on level *changes* meant silence
/// -- no new samples -- froze the whole strip mid-shape, which reads as a
/// hung app rather than a live mic.
struct WaveformHUD: View {
    let model: HUDModel

    /// Rolling history of recent levels, oldest first, held at a fixed
    /// length. This view's `@State` outlives any single recording -- the
    /// panel is reused across sessions, not rebuilt -- so the buffer has to
    /// bound itself rather than trust a caller to clear it, or a half-hour
    /// dictation would grow it without limit.
    @State private var levels: [Float] = Array(repeating: 0, count: WaveformHUD.sampleCount)

    /// Live mirror of `model.level`, kept current by `.onChange` below.
    ///
    /// The scroll loop in `.task` cannot read `model.level` directly:
    /// `model` is a plain `let`, so the closure `.task` launches captures
    /// whichever `model` was current the moment the task started, and goes
    /// on reading that one snapshot for as long as the task runs -- even
    /// though `body` keeps re-evaluating with fresh `model` values around
    /// it. `@State` doesn't have that problem: its storage is a box owned
    /// by SwiftUI and shared by every copy of this view, including the one
    /// the task closure captured, so mirroring the level into `@State`
    /// here is what gives the loop a live value to read.
    @State private var latestLevel: Float = 0

    private static let sampleCount = 48
    private let barMinHeight: CGFloat = 3
    private let barMaxHeight: CGFloat = 22

    /// A gentle synthetic floor, slowly cycled, blended under the real
    /// level while listening. A live mic's noise floor is not guaranteed to
    /// vary on its own, and a clock that faithfully repeats an
    /// exactly-flat real reading would scroll data that *looks*, to the
    /// eye, identical to not scrolling at all -- this is what keeps the
    /// strip visibly, calmly alive through silence instead of just
    /// technically live underneath a static-looking line.
    private let idleFloorBase: Float = 0.2
    private let idleFloorAmplitude: Float = 0.09

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusLine
            waveform
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(width: 380, height: 56, alignment: .leading)
        // A live blur of whatever sits behind this borderless window, not
        // just a tinted material -- see VisualEffectBackground's own doc.
        // It goes in a view builder, not `background(_:in:)`: that overload
        // takes a ShapeStyle, and this is an NSViewRepresentable. The
        // trailing .clipShape below is what rounds it and keeps the blur
        // from spilling past the rounded corners. `emphasized` pushes the
        // vibrancy further, same as Frosted -- the plain, unemphasized
        // material read as too faint a blur on its own.
        .background { VisualEffectBackground(emphasized: true) }
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .clipShape(shape)
        .onChange(of: model.level) { _, newLevel in
            latestLevel = newLevel
        }
        .onChange(of: model.phase) { oldPhase, newPhase in
            // Without this, starting a new recording would briefly flash
            // the previous session's frozen tail before fresh samples had a
            // chance to overwrite it.
            if newPhase == .listening, oldPhase != .listening {
                levels = Array(repeating: 0, count: Self.sampleCount)
                latestLevel = 0
            }
        }
        .task {
            // The clock is the only thing that appends to `levels`, on a
            // fixed cadence, whether or not fresh audio has arrived. A
            // speaker falling silent stops producing new *samples*, but
            // never stops this loop, so the bars keep drifting instead of
            // freezing mid-shape.
            //
            // A plain `.task` (no `id:`) starts once for this view's
            // lifetime and is only cancelled if the view itself is torn
            // down -- switching HUD designs, say -- not by silence.
            // `model.level` and `model.phase` changing, or not changing,
            // has no bearing on this view's identity, so a pause in speech
            // can never stall or restart the loop.
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                tick += 1
                let idleFloor = idleFloorBase + idleFloorAmplitude * Float(sin(Double(tick) * 0.1))
                levels.append(max(latestLevel, idleFloor))
                if levels.count > Self.sampleCount {
                    levels.removeFirst(levels.count - Self.sampleCount)
                }
            }
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    // MARK: - Transcript

    private var statusLine: some View {
        HStack(spacing: 6) {
            statusIcon
                .frame(width: 14, height: 14)
            Group {
                if case .failed(let message) = model.phase {
                    Text(message).foregroundStyle(.primary)
                } else {
                    TranscriptText(model: model, font: .system(size: 12))
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.head)

            if case .working(let label) = model.phase {
                Spacer(minLength: 8)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.phase {
        case .listening:
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
        case .working:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        }
    }

    // MARK: - Waveform

    /// The real buffer while listening; a flat array of the same length the
    /// rest of the time. Deriving the flat state instead of mutating
    /// `levels` directly is what lets the bars *ease down* to calm when a
    /// recording ends, via the `.animation` below, instead of staying
    /// frozen on whatever spike was last captured.
    private var displayLevels: [Float] {
        model.phase == .listening ? levels : Array(repeating: 0, count: levels.count)
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            // Bars are keyed by slot, not by sample. When a new reading
            // pushes the array along, every bar just eases from its old
            // height to its neighbour's old height -- a cheap illusion of
            // scrolling that needs no per-frame clock to drive the visual
            // interpolation, only the once-per-tick append in `.task`.
            ForEach(displayLevels.indices, id: \.self) { index in
                Capsule()
                    .fill(waveformTint.opacity(model.phase == .listening ? 0.85 : 0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: barHeight(displayLevels[index]))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: barMaxHeight)
        // The newest sample sits at the trailing edge; the leading edge is
        // the oldest, about to scroll off, so fading it there is what sells
        // "drifting left" rather than a hard, cut-off edge.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.16),
                    .init(color: .black, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing))
        .animation(.easeOut(duration: 0.12), value: displayLevels)
    }

    private var waveformTint: Color {
        switch model.phase {
        case .listening: return .accentColor
        case .working: return .secondary
        case .failed: return .orange
        case .done: return .green
        }
    }

    private func barHeight(_ sample: Float) -> CGFloat {
        let amount = CGFloat(min(max(sample, 0), 1))
        return max(barMinHeight, amount * barMaxHeight)
    }
}
