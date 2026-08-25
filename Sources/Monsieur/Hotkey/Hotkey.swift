import AppKit
import Carbon.HIToolbox

/// A hotkey parsed from a human-writable string such as `"ctrl+alt+space"`.
/// Keeping the on-disk format textual means the JSON config stays hand-editable.
struct Hotkey: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, ...).
    var carbonModifiers: UInt32

    var cocoaModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }

    // MARK: Parsing

    static func parse(_ string: String) -> Hotkey? {
        let parts = string.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyName = parts.last else { return nil }

        var mods: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "meta", "super": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case "alt", "opt", "option": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            default: return nil
            }
        }
        guard let code = keyCodes[keyName] else { return nil }
        return Hotkey(keyCode: code, carbonModifiers: mods)
    }

    /// Human-readable form for the UI, e.g. "⌃⌥Space".
    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (Self.names[keyCode]?.capitalized ?? "?")
    }

    /// Reverse lookup for `display`. Built once and deterministically:
    /// dictionary iteration order is not guaranteed, so picking "whichever
    /// name happens to come first" could render the same binding as `Return`
    /// one launch and `Enter` the next.
    private static let names: [UInt32: String] = {
        var map: [UInt32: String] = [:]
        // Seeded first so the preferred spelling wins over its alias.
        for name in ["return", "grave", "escape"] {
            if let code = keyCodes[name] { map[code] = name }
        }
        for name in keyCodes.keys.sorted() {
            let code = keyCodes[name]!
            if map[code] == nil { map[code] = name }
        }
        return map
    }()

    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28,
        "9": 25, "0": 29,
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "grave": 50, "backtick": 50, "minus": 27, "equal": 24,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105,
        "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
        "f20": 90,
    ]
}
