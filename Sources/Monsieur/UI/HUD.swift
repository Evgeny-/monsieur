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
    private var shownWithText: Bool?
    private var isPreviewing = false
    private var previewTask: Task<Void, Never>?

    /// Breathing room around the design so a soft shadow has somewhere to fall.
    /// Without it the window edge would clip the shadow flat.
    static let shadowMargin: CGFloat = 18

    private init() {}

    /// The overlay is small on purpose, and smaller still when it has nothing to
    /// say. Wherever it sits it covers something.
    static func size(showingText: Bool) -> CGSize {
        showingText ? CGSize(width: 340, height: 44) : CGSize(width: 74, height: 40)
    }

    func show(controller: DictationController, settings: Settings) {
        if panel == nil || shownWithText != settings.showLiveText || isPreviewing {
            isPreviewing = false
            rebuild(controller: controller, settings: settings, sample: nil)
        }
        reposition(settings: settings)
        panel?.orderFrontRegardless()
    }

    func hide() {
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        // Torn down rather than ordered out: a hidden window keeps its hosting
        // view alive, and with it any animation loop inside the design.
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        shownWithText = nil
    }

    /// Shows the overlay briefly with sample content, so changing a setting
    /// shows you the result instead of making you dictate to find out.
    func preview(controller: DictationController, settings: Settings) {
        guard !controller.state.isBusy else { return }
        isPreviewing = true
        rebuild(controller: controller, settings: settings, sample: .sample)
        reposition(settings: settings)
        panel?.orderFrontRegardless()
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, isPreviewing else { return }
            hide()
        }
    }

    private func rebuild(controller: DictationController, settings: Settings, sample: HUDModel?) {
        panel?.orderOut(nil)
        let content = Self.size(showingText: settings.showLiveText)
        let size = CGSize(width: content.width + Self.shadowMargin * 2,
                          height: content.height + Self.shadowMargin * 2)
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = NSHostingView(
            rootView: HUDHost(controller: controller,
                              showText: settings.showLiveText, sample: sample))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit's window shadow is a heavy dark halo; the design draws its own.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        self.panel = panel
        self.shownWithText = settings.showLiveText
    }

    private func reposition(settings: Settings) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let content = Self.size(showingText: settings.showLiveText)
        let size = CGSize(width: content.width + Self.shadowMargin * 2,
                          height: content.height + Self.shadowMargin * 2)
        panel.setContentSize(NSSize(width: size.width, height: size.height))
        // The margin is padding inside the window, so the visible pill would sit
        // further from the edge than asked; offset it back out.
        let origin = settings.hudPosition.origin(for: size, in: visible)
        panel.setFrameOrigin(NSPoint(x: origin.x - Self.shadowMargin,
                                     y: origin.y - Self.shadowMargin))

        let f = panel.frame
        if let screenHeight = screen?.frame.height {
            Log.app.info("hud rect \(Int(f.origin.x)),\(Int(screenHeight - f.origin.y - f.height)),\(Int(f.width)),\(Int(f.height))")
        }
    }
}

// MARK: - Host

/// Observes the controller and hands the overlay a plain value, so the view
/// itself stays pure.
private struct HUDHost: View {
    @ObservedObject var controller: DictationController
    let showText: Bool
    var sample: HUDModel?

    var body: some View {
        MonsieurHUD(model: displayed, showText: showText)
            .shadow(color: .black.opacity(0.30), radius: 9, y: 3)
            .padding(HUDController.shadowMargin)
            .animation(.easeOut(duration: 0.18), value: displayed.committedText)
            .animation(.easeOut(duration: 0.12), value: displayed.partialText)
    }

    private var displayed: HUDModel { sample ?? model }

    private var model: HUDModel {
        HUDModel(
            phase: phase,
            committedText: Self.tail(of: controller.committedText),
            partialText: controller.partialText,
            level: controller.level)
    }

    private var phase: HUDModel.Phase {
        switch controller.state {
        case .recording: return .listening
        case .working(let label): return .working(label)
        case .failed(let message): return .failed(message)
        case .idle: return .done
        }
    }

    /// The overlay shows one line; a half-hour dictation accumulates tens of
    /// thousands of characters, and SwiftUI would lay out every one of them on
    /// each update. Hand over only the tail.
    private static func tail(of text: String, limit: Int = 300) -> String {
        guard text.count > limit else { return text }
        let cut = text.index(text.endIndex, offsetBy: -limit)
        if let space = text[cut...].firstIndex(of: " ") {
            return String(text[text.index(after: space)...])
        }
        return String(text[cut...])
    }
}
