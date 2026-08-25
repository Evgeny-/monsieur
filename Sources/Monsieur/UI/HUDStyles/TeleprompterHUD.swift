import SwiftUI

/// "Teleprompter": the last couple of lines of speech drift upward as more
/// words arrive, autocue-style. Per the brief this design carries the whole
/// "I'm listening" signal through that motion, so unlike the other styles it
/// has no status title or icon competing with it -- only `.working` and
/// `.failed` get any chrome at all, and both stay out of the text's way.
struct TeleprompterHUD: View {
    let model: HUDModel

    // Fixed design constants, not per-instance configuration -- `static` so
    // they stay out of the synthesized memberwise initializer (a `private`
    // *instance* stored property would downgrade that initializer's access
    // level and break the `TeleprompterHUD(model:)` call in HUDStyle.swift).
    //
    // Must match `HUDStyleID.preferredSize` for `.teleprompter` exactly, not
    // just be close: `HUDController.reposition` grows the real panel to fit
    // this view's `fittingSize` whenever it exceeds the preferred size, and
    // never shrinks it back down. A larger internal frame here is exactly
    // how the previous pass ended up bulkier than the window it sat in.
    private static let hudSize = CGSize(width: 460, height: 51)
    private static let font: Font = .system(size: 13)

    /// Fixed rather than measured from font metrics: this is a panel-sized
    /// window the text scrolls through, not a box that should grow to fit
    /// its content -- growing would defeat the "two lines" brief and make
    /// the panel jump around as speech comes in.
    /// Exactly two lines: the 16pt line box of SF 13pt, twice, plus the 3pt
    /// of `lineSpacing` between them. Anything taller exposes a sliver of a
    /// third line -- visible, unreadable, and pointless.
    private static let lineWindowHeight: CGFloat = 16 * 2 + 3

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            transcript
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            cornerAccessory
                .padding(9)
        }
        .frame(width: Self.hudSize.width, height: Self.hudSize.height)
        // A live blur of the desktop behind this borderless window, not a
        // flat tinted material -- see VisualEffectBackground's own doc. It
        // goes in a view builder, not `background(_:in:)`: that overload
        // takes a ShapeStyle, and this is an NSViewRepresentable. The
        // trailing `.clipShape` below is what actually rounds it -- without
        // it the blur paints a hard rectangle straight across the
        // transparent panel instead of the thin, rounded pane of glass this
        // is meant to read as.
        .background { VisualEffectBackground() }
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .clipShape(shape)
        .animation(.easeOut(duration: 0.3), value: model.fullText)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    @ViewBuilder
    private var transcript: some View {
        if case .failed(let message) = model.phase {
            errorLine(message)
                .transition(.opacity)
        } else if model.isEmpty {
            Color.clear
        } else {
            scrollingLines
                .transition(.opacity)
        }
    }

    /// The autocue itself. `combinedText` is laid out at its full, unclamped
    /// height and then pinned to the bottom of a window shorter than that,
    /// so every new word pushes the top of the block further above the
    /// window instead of the window growing to meet it. `.clipped()` hides
    /// whatever scrolls past the top edge, and because this whole view sits
    /// inside an animated transaction (see `body`), that push reads as a
    /// continuous rise rather than a jump to a new line.
    private var scrollingLines: some View {
        combinedText
            .font(Self.font)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: Self.lineWindowHeight, alignment: .bottom)
            .clipped()
            .mask { fadeMask }
    }

    /// Committed words solid, the in-flight tail dimmed -- same convention as
    /// `TranscriptText`, rebuilt by hand because that view clamps to one
    /// line and this one needs to wrap across two.
    private var combinedText: Text {
        let committed = Text(model.committedText).foregroundStyle(.primary)
        guard !model.partialText.isEmpty else { return committed }
        let partial = Text(model.partialText).foregroundStyle(.secondary)
        guard !model.committedText.isEmpty else { return partial }
        return committed + Text(" ") + partial
    }

    private func errorLine(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.primary)
        }
        .font(Self.font)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fades the top ~60% of the window to transparent, so the departing
    /// line dissolves into the glass instead of being guillotined by the
    /// clip rect -- and doubles as a quiet resting place for
    /// `cornerAccessory`, which sits in the same corner.
    private var fadeMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.6),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    /// One corner, two occupants that never overlap in time: `.working`'s
    /// label and the listening pulse below are mutually exclusive phases, so
    /// both can share the spot the fade mask already keeps clear of text
    /// instead of each needing their own reserved space in a panel this
    /// small.
    @ViewBuilder
    private var cornerAccessory: some View {
        switch model.phase {
        case .listening:
            LevelPulse(level: model.level)
                .transition(.opacity)
        case .working(let label):
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .transition(.opacity)
        case .failed, .done:
            EmptyView()
        }
    }
}

/// A single tally-light dot standing in for a meter. The brief keeps this
/// design free of a title, an icon, and a multi-bar meter, so the
/// reintroduced voice feedback has to earn its keep in almost no space and
/// without becoming a second focal point: one dot that brightens and swells
/// with `model.level` reads as "still listening" even in a silent pause,
/// when the drifting text -- the design's main feedback signal -- has
/// nothing new to show.
private struct LevelPulse: View {
    var level: Float

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: diameter, height: diameter)
            .shadow(color: .accentColor.opacity(0.7), radius: glow)
            .animation(.easeOut(duration: 0.1), value: level)
    }

    private var clamped: Float { min(max(level, 0), 1) }
    private var diameter: CGFloat { CGFloat(4 + clamped * 4) }
    private var glow: CGFloat { CGFloat(1 + clamped * 3) }
}
