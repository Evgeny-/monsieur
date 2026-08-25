import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating panel. Non-activating is the whole point: if
/// this window ever took key focus, the caret would leave the user's text field
/// and there would be nowhere left to paste into.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDController {

    static let shared = HUDController()

    private var panel: HUDPanel?
    private var currentStyle: HUDStyleID?
    private var isPreviewing = false
    private var previewTask: Task<Void, Never>?

    private init() {}

    func show(controller: DictationController, style: HUDStyleID) {
        // Switching designs rebuilds the panel: each one wants its own size.
        if panel == nil || currentStyle != style || isPreviewing {
            isPreviewing = false
            rebuild(controller: controller, style: style, sample: nil)
        }
        reposition(style: style)
        panel?.orderFrontRegardless()
    }

    /// Tears the panel down rather than just ordering it out.
    ///
    /// A hidden window keeps its hosting view alive, and a hosting view keeps
    /// any `.task` animation loop inside a design running -- one of them ticks
    /// at 20 Hz -- so an ordered-out overlay would go on re-rendering for as
    /// long as the app was open. Rebuilding costs a window and a hosting view,
    /// which is nothing next to that, and it guarantees no design can leak a
    /// loop no matter how it is written.
    func hide() {
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        currentStyle = nil
    }

    /// Shows the HUD briefly with sample content, so switching designs from the
    /// menu previews the result instead of making you dictate to see it.
    ///
    /// Real content matters here: previewing with the live (empty) model would
    /// show every design as an empty box, which is no basis for choosing one.
    func preview(controller: DictationController, style: HUDStyleID) {
        guard !controller.state.isBusy else { return }
        isPreviewing = true
        rebuild(controller: controller, style: style, sample: .sample)
        reposition(style: style)
        panel?.orderFrontRegardless()
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .seconds(5.5))
            guard !Task.isCancelled, isPreviewing else { return }
            isPreviewing = false
            hide()
        }
    }

    /// Breathing room around the design so a soft shadow has somewhere to
    /// fall. Without it the window edge would clip the shadow flat.
    static let shadowMargin: CGFloat = 18

    private func rebuild(controller: DictationController, style: HUDStyleID,
                         sample: HUDModel?) {
        panel?.orderOut(nil)
        let size = CGSize(width: style.preferredSize.width + Self.shadowMargin * 2,
                          height: style.preferredSize.height + Self.shadowMargin * 2)
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = NSHostingView(
            rootView: HUDHost(controller: controller, style: style, sample: sample))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit's window shadow is a heavy dark halo, which around a small
        // dark capsule on a dark desktop reads as a black outline rather than
        // as depth. The designs draw their own, softer shadow instead -- see
        // the margin below, which gives it somewhere to fall.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        self.panel = panel
        self.currentStyle = style
    }

    private func reposition(style: HUDStyleID) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        // The declared size is authoritative. Sizing to the view's fittingSize
        // instead let a design quietly grow the window past what it declared --
        // which is what made one variant render noticeably bulkier than
        // intended -- and made the on-screen footprint depend on the content.
        let margin = Self.shadowMargin * 2
        let size = CGSize(width: style.preferredSize.width + margin,
                          height: style.preferredSize.height + margin)
        panel.setContentSize(NSSize(width: size.width, height: size.height))
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 90 - Self.shadowMargin))

        // Reported in screencapture's coordinate space (origin top-left) rather
        // than AppKit's (origin bottom-left), so tooling can frame the overlay
        // without having to know which convention applies where.
        if let screenHeight = screen?.frame.height {
            let f = panel.frame
            Log.app.info("hud rect \(Int(f.origin.x)),\(Int(screenHeight - f.origin.y - f.height)),\(Int(f.width)),\(Int(f.height))")
        }
    }
}

// MARK: - Host

/// Observes the controller and hands the chosen design a plain value. Designs
/// stay pure views, which is what makes them cheap to write and swap.
private struct HUDHost: View {
    @ObservedObject var controller: DictationController
    let style: HUDStyleID
    /// When set, the design is fed this instead of live state -- used by the
    /// menu's style preview.
    var sample: HUDModel?

    @State private var sampleLevel: Float = 0.4
    @State private var samplePhase: HUDModel.Phase = .listening

    var body: some View {
        style.makeView(model: displayed)
            .shadow(color: .black.opacity(0.30), radius: 9, y: 3)
            .padding(HUDController.shadowMargin)
            .animation(.easeOut(duration: 0.18), value: displayed.committedText)
            .animation(.easeOut(duration: 0.12), value: displayed.partialText)
            .task {
                guard sample != nil else { return }
                // Walk the preview through the phases a real dictation goes
                // through. Showing only the listening state hid the fact that
                // two designs said nothing at all while the model was working.
                var step = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(90))
                    step += 1
                    // Give level-driven designs something to move to, otherwise
                    // the waveform previews as a flat line.
                    sampleLevel = Float(0.25 + 0.55 * abs(sin(Double(step) / 3.1)))
                    switch step {
                    case 28: samplePhase = .working("Rewriting…")
                    case 45: samplePhase = .done
                    default: break
                    }
                }
            }
    }

    private var displayed: HUDModel {
        guard var sample else { return model }
        sample.level = sampleLevel
        sample.phase = samplePhase
        if case .working = samplePhase { sample.partialText = "" }
        return sample
    }

    private var model: HUDModel {
        HUDModel(
            phase: phase,
            committedText: Self.tail(of: controller.committedText),
            partialText: controller.partialText,
            level: controller.level)
    }

    /// Designs only ever show the last line or two, but a half-hour dictation
    /// accumulates tens of thousands of characters -- and SwiftUI would lay out
    /// every one of them on each update. Hand over only the tail.
    private static func tail(of text: String, limit: Int = 400) -> String {
        guard text.count > limit else { return text }
        let cut = text.index(text.endIndex, offsetBy: -limit)
        // Resume at a word boundary so the visible text does not start mid-word.
        if let space = text[cut...].firstIndex(of: " ") {
            return String(text[text.index(after: space)...])
        }
        return String(text[cut...])
    }

    private var phase: HUDModel.Phase {
        switch controller.state {
        case .recording: return .listening
        case .working(let label): return .working(label)
        case .failed(let message): return .failed(message)
        case .idle: return .done
        }
    }
}
