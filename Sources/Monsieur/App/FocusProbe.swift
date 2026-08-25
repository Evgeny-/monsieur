import AppKit
import ApplicationServices

/// Diagnostic for the "is there anywhere to put this text?" question.
///
/// The rule that answers it has to be calibrated against what real applications
/// actually report, not against what the Accessibility documentation implies:
/// Electron and web content routinely report no focused element at all while
/// accepting a paste perfectly well.
@MainActor
enum FocusProbe {

    static func run() -> Int32 {
        print("system-wide focused element:")
        describe(AXUIElementCreateSystemWide(), indent: "  ")

        print("\nper-application focused element:")
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        for app in apps {
            let name = app.localizedName ?? "pid \(app.processIdentifier)"
            let marker = app.isActive ? "*" : " "
            print("\(marker) \(name)")
            describe(AXUIElementCreateApplication(app.processIdentifier), indent: "    ")
        }
        print("\n(* = frontmost)")
        return 0
    }

    private static func describe(_ element: AXUIElement, indent: String) {
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXFocusedUIElementAttribute as CFString, &focused)

        guard status == .success else {
            print("\(indent)focused: <\(name(for: status))>")
            return
        }
        guard let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            print("\(indent)focused: <not an AXUIElement>")
            return
        }
        let target = value as! AXUIElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXSubroleAttribute as CFString, &subrole)

        var range: CFTypeRef?
        let hasRange = AXUIElementCopyAttributeValue(
            target, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        var selected: CFTypeRef?
        let hasSelectedText = AXUIElementCopyAttributeValue(
            target, kAXSelectedTextAttribute as CFString, &selected) == .success

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(
            target, kAXSelectedTextAttribute as CFString, &settable)

        print("\(indent)role=\((role as? String) ?? "-")"
            + " subrole=\((subrole as? String) ?? "-")"
            + " selectedTextRange=\(hasRange)"
            + " selectedText=\(hasSelectedText)"
            + " settable=\(settable.boolValue)")
    }

    private static func name(for status: AXError) -> String {
        switch status {
        case .success: return "success"
        case .noValue: return "noValue"
        case .attributeUnsupported: return "attributeUnsupported"
        case .apiDisabled: return "apiDisabled — no Accessibility permission"
        case .invalidUIElement: return "invalidUIElement"
        case .cannotComplete: return "cannotComplete"
        case .notImplemented: return "notImplemented"
        default: return "error \(status.rawValue)"
        }
    }
}
