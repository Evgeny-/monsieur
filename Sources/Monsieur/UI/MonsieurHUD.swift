import SwiftUI

/// The overlay. One design, in two sizes: with the transcript, or with only a
/// dot that reacts to your voice.
///
/// There used to be five designs. They were interesting to build and none of
/// them earned their keep -- the one that gets used is the one that says the
/// least, and every extra design was another thing to keep working through
/// every change to the app underneath.
struct MonsieurHUD: View {
    let model: HUDModel
    var showText: Bool = true

    var body: some View {
        Group {
            if showText {
                HStack(spacing: 9) {
                    indicator
                    content
                        // Text is laid out on its full line box, ascender to
                        // descender, but the eye centres on the band of
                        // lowercase letters, which sits about a point lower.
                        // Nudged up so it looks centred rather than merely
                        // being so.
                        .offset(y: -1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(width: 340, height: 44, alignment: .leading)
            } else {
                indicator
                    .frame(width: 74, height: 40)
            }
        }
        .background { VisualEffectBackground() }
        .clipShape(shape)
        // A lit hairline along the edge. Without it the capsule ends in nothing
        // and the boundary reads as a dark outline rather than as the rim of a
        // piece of glass; brighter at the top, as light would be.
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1))
    }

    private var shape: Capsule { Capsule(style: .continuous) }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .failed(let message):
            Text(message).font(font).foregroundStyle(.orange).lineLimit(1)
        case .working(let label):
            // Replacing the transcript rather than covering it: by now the
            // transcript is final and about to be swapped for the polished
            // version anyway, so the status is the only live information left.
            Text(label).font(font).foregroundStyle(.secondary).lineLimit(1)
        case .listening, .done:
            TranscriptText(model: model, font: font)
                .lineLimit(1)
                // Head truncation keeps the newest words on screen as the line
                // fills: for a live transcript the tail is what matters.
                .truncationMode(.head)
        }
    }

    private var font: Font { .system(size: 13, weight: .medium) }

    @ViewBuilder
    private var indicator: some View {
        ZStack {
            if case .working = model.phase {
                ProgressView().controlSize(.small)
            } else {
                if model.phase == .listening {
                    Circle()
                        .fill(tint.opacity(0.18 + Double(level) * 0.45))
                        .frame(width: 9 + level * 13, height: 9 + level * 13)
                        .blur(radius: 2)
                }
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .scaleEffect(model.phase == .listening ? 1 + level * 0.5 : 1)
            }
        }
        .frame(width: 22, height: 22)
        .animation(.easeOut(duration: 0.08), value: model.level)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    private var level: CGFloat { CGFloat(min(max(model.level, 0), 1)) }

    private var tint: Color {
        switch model.phase {
        case .listening, .working: return .accentColor
        case .failed: return .orange
        case .done: return .green
        }
    }
}
