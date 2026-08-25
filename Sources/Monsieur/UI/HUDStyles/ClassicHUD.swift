import SwiftUI

/// The original design: a rounded pill with a status line, the transcript, and
/// a five-bar level meter.
struct ClassicHUD: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            indicator
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Group {
                    if case .failed(let message) = model.phase {
                        Text(message).foregroundStyle(.primary)
                    } else {
                        TranscriptText(model: model)
                    }
                }
                .font(.system(size: 13))
                .lineLimit(2)
                .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.phase {
        case .listening:
            BarMeter(level: model.level).frame(width: 26, height: 26)
        case .working:
            ProgressView().controlSize(.small).frame(width: 26, height: 26)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).frame(width: 26, height: 26)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).frame(width: 26, height: 26)
        }
    }

    private var title: String {
        switch model.phase {
        case .listening: return "Listening"
        case .working(let label): return label
        case .failed: return "Problem"
        case .done: return "Done"
        }
    }
}

/// Five bars weighted differently so the meter reads as a waveform rather than
/// a single level.
struct BarMeter: View {
    var level: Float
    var weights: [Float] = [0.45, 0.8, 1.0, 0.7, 0.35]
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 20

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: barWidth, height: height(weights[i]))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func height(_ weight: Float) -> CGFloat {
        CGFloat(4 + min(max(level * weight, 0), 1) * Float(maxHeight))
    }
}
