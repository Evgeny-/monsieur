import Foundation

/// Lets another process start and stop dictation.
///
/// Exists so the app can be driven by a script -- recording the demo needs the
/// hotkey pressed without a human -- but it is equally the hook for Stream
/// Deck, Raycast, or a shell alias. A distributed notification is enough: it
/// crosses process boundaries, needs no permission of its own, and carries no
/// payload worth attacking.
enum RemoteControl {

    enum Command: String, CaseIterable {
        case toggle = "dev.enikiforov.monsieur.toggle"
        case toggleVerbatim = "dev.enikiforov.monsieur.toggleVerbatim"
        /// Explicit start and stop, for callers that cannot see the current
        /// state. A toggle desynchronises the moment one arrives while the app
        /// is still finishing the previous dictation: the caller believes it
        /// started a recording and actually stopped nothing, then the next
        /// toggle starts one over whatever silence follows. That produced
        /// transcripts of rooms nobody was speaking in.
        case start = "dev.enikiforov.monsieur.start"
        case stop = "dev.enikiforov.monsieur.stop"
        case cancel = "dev.enikiforov.monsieur.cancel"
    }

    /// Called by the running app.
    @MainActor
    static func listen(controller: DictationController) {
        let center = DistributedNotificationCenter.default()
        for command in Command.allCases {
            center.addObserver(forName: Notification.Name(command.rawValue),
                               object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Log.app.info("remote: \(command.rawValue, privacy: .public)")
                    switch command {
                    case .toggle: controller.toggle()
                    case .toggleVerbatim: controller.toggle(bypassLLM: true)
                    case .start: controller.start()
                    case .stop: controller.stop()
                    case .cancel: controller.cancel()
                    }
                }
            }
        }
    }

    /// Called by the short-lived process started from the command line.
    static func send(_ command: Command) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(command.rawValue), object: nil,
            userInfo: nil, deliverImmediately: true)
    }
}
