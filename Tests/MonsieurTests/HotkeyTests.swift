import Carbon.HIToolbox
import Testing

@testable import Monsieur

/// `Hotkey.parse` turns a hand-typed string like `"ctrl+alt+space"` into a
/// Carbon key code and modifier mask. It is the only thing standing between a
/// typo in `settings.json` and a hotkey that silently never fires, so the
/// parser needs to fail closed (return nil) on anything it cannot confidently
/// resolve, and succeed on everything `keyCodes` claims to support.
struct HotkeyParseTests {

    // MARK: - Modifier aliases

    @Test("cmd/command/meta/super all resolve to the Carbon command modifier",
          arguments: ["cmd", "command", "meta", "super"])
    func commandAliases(_ alias: String) {
        let hk = Hotkey.parse("\(alias)+a")
        #expect(hk?.carbonModifiers == UInt32(cmdKey))
        #expect(hk?.keyCode == 0)
    }

    @Test("ctrl/control both resolve to the Carbon control modifier",
          arguments: ["ctrl", "control"])
    func controlAliases(_ alias: String) {
        let hk = Hotkey.parse("\(alias)+a")
        #expect(hk?.carbonModifiers == UInt32(controlKey))
    }

    @Test("alt/opt/option all resolve to the Carbon option modifier",
          arguments: ["alt", "opt", "option"])
    func optionAliases(_ alias: String) {
        let hk = Hotkey.parse("\(alias)+a")
        #expect(hk?.carbonModifiers == UInt32(optionKey))
    }

    @Test func shiftResolvesToShiftModifier() {
        let hk = Hotkey.parse("shift+a")
        #expect(hk?.carbonModifiers == UInt32(shiftKey))
    }

    // MARK: - Combinations

    @Test func allFourModifiersCombine() {
        let hk = Hotkey.parse("ctrl+alt+shift+cmd+a")
        let expected = UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey)
        #expect(hk?.carbonModifiers == expected)
        #expect(hk?.keyCode == 0)
    }

    @Test func orderOfModifiersDoesNotMatter() {
        let a = Hotkey.parse("ctrl+alt+space")
        let b = Hotkey.parse("alt+ctrl+space")
        #expect(a == b)
    }

    @Test func repeatingTheSameModifierIsHarmless() {
        let hk = Hotkey.parse("ctrl+ctrl+space")
        #expect(hk?.carbonModifiers == UInt32(controlKey))
    }

    @Test func noModifiersAtAllIsValid() {
        let hk = Hotkey.parse("space")
        #expect(hk?.carbonModifiers == 0)
        #expect(hk?.keyCode == 49)
    }

    // MARK: - Case and whitespace tolerance (hand-edited JSON is messy)

    @Test func isCaseInsensitive() {
        #expect(Hotkey.parse("CTRL+ALT+SPACE") == Hotkey.parse("ctrl+alt+space"))
        #expect(Hotkey.parse("Cmd+D") == Hotkey.parse("cmd+d"))
    }

    @Test func tolerateStraySpacesAroundPartsAndPlusSigns() {
        let hk = Hotkey.parse("  ctrl + alt  +  space  ")
        #expect(hk?.keyCode == 49)
        #expect(hk?.carbonModifiers == UInt32(controlKey) | UInt32(optionKey))
    }

    // MARK: - Every named key round-trips

    /// Rather than hand-transcribing all ~50 entries of `Hotkey.keyCodes`
    /// (and risking a copy/paste mistake that tests the copy rather than the
    /// parser), assert the table is self-consistent: every name it advertises
    /// actually parses back to the code it promises, with no modifiers.
    @Test func everyNamedKeyParsesToItsOwnCode() {
        for (name, code) in Hotkey.keyCodes {
            let hk = Hotkey.parse(name)
            #expect(hk?.keyCode == code, "key name \"\(name)\" did not round-trip")
            #expect(hk?.carbonModifiers == 0, "key name \"\(name)\" should carry no modifiers alone")
        }
    }

    @Test func functionKeysParseWithModifiers() {
        let hk = Hotkey.parse("cmd+f13")
        #expect(hk?.keyCode == 105)
        #expect(hk?.carbonModifiers == UInt32(cmdKey))
    }

    // MARK: - Rejection of nonsense

    @Test func emptyStringIsRejected() {
        #expect(Hotkey.parse("") == nil)
    }

    @Test func whitespaceOnlyStringIsRejected() {
        #expect(Hotkey.parse("   ") == nil)
    }

    @Test func onlyPlusSignsIsRejected() {
        #expect(Hotkey.parse("+++") == nil)
    }

    @Test func unknownKeyNameAloneIsRejected() {
        #expect(Hotkey.parse("banana") == nil)
    }

    @Test func validModifierWithUnknownKeyIsRejected() {
        #expect(Hotkey.parse("cmd+banana") == nil)
    }

    @Test func unknownModifierWithValidKeyIsRejected() {
        // The first token is checked as a modifier keyword even though the
        // string ends in a real key name -- an unrecognised modifier fails
        // the whole parse rather than being ignored.
        #expect(Hotkey.parse("banana+space") == nil)
    }

    @Test func bareModifierWordAloneIsRejected() {
        // "shift" alone has no trailing key: it is treated as the *key name*
        // (there being nothing after it), and "shift" is not in `keyCodes`.
        #expect(Hotkey.parse("shift") == nil)
        #expect(Hotkey.parse("ctrl") == nil)
        #expect(Hotkey.parse("ctrl+") == nil)
    }

    // MARK: - display round trip

    @Test func displayMatchesTheReadmesOwnExample() {
        // README.md documents "⌃⌥Space" as the default hotkey's display form.
        // If this regresses, the README goes stale silently.
        #expect(Hotkey.parse("ctrl+alt+space")?.display == "⌃⌥Space")
    }

    @Test func displaySymbolOrderIsAlwaysControlOptionShiftCommand() {
        // Symbol order in `display` is fixed (⌃⌥⇧⌘) regardless of the order
        // modifiers were written in the source string.
        #expect(Hotkey.parse("cmd+shift+d")?.display == "⇧⌘D")
        #expect(Hotkey.parse("shift+cmd+d")?.display == "⇧⌘D")
    }

    @Test func displayCapitalizesTheKeyName() {
        #expect(Hotkey.parse("cmd+a")?.display == "⌘A")
        #expect(Hotkey.parse("f1")?.display == "F1")
    }

    @Test func displayWithNoModifiersIsJustTheKey() {
        #expect(Hotkey.parse("a")?.display == "A")
    }

    @Test func displayFallsBackToQuestionMarkForAnUnknownKeyCode() {
        // Not reachable via `.parse` (which always assigns a code from the
        // table), but `display` is also called on hand-built `Hotkey` values
        // elsewhere, so its fallback for an unmapped code is worth pinning.
        let hk = Hotkey(keyCode: 9999, carbonModifiers: 0)
        #expect(hk.display == "?")
    }

    @Test func displayForDuplicateCodedKeysIsOneOfTheKnownAliases() {
        // "return" and "enter" share key code 36, and `display` recovers a
        // name via `keyCodes.first { $0.value == keyCode }` -- on an
        // unordered Dictionary that is one of the two names, not
        // deterministically either one. This pins the fallback to "does not
        // crash and picks a valid alias" rather than a specific string, since
        // asserting an exact name here would be a flaky test, not a real bug.
        let hk = Hotkey.parse("return")
        #expect(hk?.display == "Return" || hk?.display == "Enter")
    }
}
