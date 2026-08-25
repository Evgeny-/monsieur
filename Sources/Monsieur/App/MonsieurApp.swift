import AppKit

@main
enum MonsieurApp {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1 { CommandLineModes.unbufferOutput() }

        if let index = arguments.firstIndex(of: "--process") {
            guard arguments.count > index + 1 else { usage() }
            exit(CommandLineModes.process(text: arguments[index + 1],
                                          verbose: arguments.contains("--verbose")))
        }
        if let index = arguments.firstIndex(of: "--transcribe") {
            guard arguments.count > index + 1 else { usage() }
            exit(CommandLineModes.transcribe(path: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--signal"),
           arguments.count > index + 1,
           let command = RemoteControl.Command(
               rawValue: "dev.enikiforov.monsieur." + arguments[index + 1]) {
            RemoteControl.send(command)
            exit(0)
        }
        if arguments.contains("--probe-focus") {
            exit(FocusProbe.run())
        }
        if arguments.contains("--check") {
            exit(CommandLineModes.check())
        }
        if arguments.contains("--preview-hud") {
            previewHUD()
            return
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            usage()
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // .accessory keeps us out of the Dock and the app switcher: this is a
        // menu bar utility, and more importantly it must never steal focus from
        // the text field the user is dictating into.
        application.setActivationPolicy(.accessory)
        application.run()
    }

    /// Shows the overlay with sample content, where and how the settings say,
    /// then quits. Cheaper than dictating to find out.
    @MainActor
    private static func previewHUD() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let controller = DictationController.shared
        let settings = SettingsStore.shared.settings
        print("\(settings.hudPosition.label), \(settings.showLiveText ? "with text" : "dot only")")
        Task { @MainActor in
            HUDController.shared.preview(controller: controller, settings: settings)
            try? await Task.sleep(for: .seconds(4.5))
            HUDController.shared.hide()
            try? await Task.sleep(for: .milliseconds(300))
            exit(0)
        }
        application.run()
    }

    private static func usage() -> Never {
        FileHandle.standardError.write(Data("""
        Monsieur — dictate anywhere on macOS.

        Run with no arguments to start the menu bar app. Diagnostics:

          --check                    show configuration and permission status
          --process "text" [-v]      run only the rewriting stage on some text
          --transcribe file.wav      run a file through transcription + rewriting
          --preview-hud              show the overlay where the settings put it
          --probe-focus              report what every app exposes as its focused element
          --signal <start|stop|toggle|toggleVerbatim|cancel>
                                     drive the running app from a script

        """.utf8))
        exit(2)
    }
}
