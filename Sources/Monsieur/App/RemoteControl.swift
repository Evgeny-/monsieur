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
