import AppKit
import Testing

@testable import Monsieur

/// `HUDStyleID.allCases` drives both the menu bar switcher and the Settings
/// picker (README.md › Overlay styles), and `preferredSize` fixes the
/// panel's dimensions so a design can fill it exactly rather than resize as
/// words arrive -- a jittering panel is called out in the source comment as
/// worse than a little empty space. A case that slipped through with a zero
/// or negative size would render as an invisible or degenerate panel.
struct HUDStyleIDTests {

    @Test func everyCaseHasAPositivePreferredSize() {
        for style in HUDStyleID.allCases {
            let size = style.preferredSize
            #expect(size.width > 0, "\(style) has non-positive width \(size.width)")
            #expect(size.height > 0, "\(style) has non-positive height \(size.height)")
        }
    }

    @Test func allCasesIsExactlyTheDocumentedFiveStyles() {
        // README.md › Overlay styles documents five designs by name. Compared
        // by raw value (plain strings) rather than relying on the enum's own
        // Equatable/Hashable synthesis. Adding a sixth design (one file in
        // HUDStyles/ plus a case here, per the README) should require a
        // conscious update to this test, not slip through unnoticed.
        let rawValues = Set(HUDStyleID.allCases.map(\.rawValue))
        let documented: Set<String> = ["minimal", "classic", "frosted", "teleprompter", "waveform"]
        #expect(rawValues == documented)
    }

    @Test func everyCaseHasNonEmptyDisplayNameAndDetail() {
        for style in HUDStyleID.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.detail.isEmpty)
        }
    }

    @Test func everyCaseRoundTripsThroughItsRawValue() {
        // `hudStyle` is persisted in settings.json as this raw string; a case
        // that failed to round-trip would silently reset to the default the
        // next time the file was read back.
        for style in HUDStyleID.allCases {
            #expect(HUDStyleID(rawValue: style.rawValue) == style)
        }
    }
}
