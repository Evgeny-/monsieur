import Foundation
import Testing

@testable import Monsieur

/// `Settings` is meant to be hand-edited as JSON (see README.md ›
/// Configuration). Every stored property is decoded through a small
/// per-field helper that swallows a decode failure for *that field* and
/// substitutes its own default, so a file that is missing keys, carries
/// stale keys, or has a typo'd value in one field still loads -- it does not
/// take the rest of the file down with it. These tests exercise that
/// contract directly.
///
/// Deliberately not hard-coded: today's literal default values (they live in
/// `Settings.init()`, which is free to change independently of the decoding
/// contract these tests actually care about). Comparisons are against a
/// freshly constructed `Settings()` wherever "falls back to the default" is
/// the thing under test.
struct SettingsDecodingTests {

    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    // MARK: - Empty / missing keys

    @Test func emptyObjectDecodesToAllDefaults() throws {
        #expect(try decode("{}") == Settings())
    }

    @Test func fileWithOnlyAFewKeysStillLoadsWithDefaultsForTheRest() throws {
        let settings = try decode("""
        {"anthropicModel": "claude-haiku-4-5", "targetLanguage": "French"}
        """)
        #expect(settings.anthropicModel == "claude-haiku-4-5")
        #expect(settings.targetLanguage == "French")

        var expected = Settings()
        expected.anthropicModel = "claude-haiku-4-5"
        expected.targetLanguage = "French"
        #expect(settings == expected)
    }

    // MARK: - Unknown keys

    @Test func unknownExtraKeysAreIgnoredNotFatal() throws {
        let settings = try decode("""
        {
          "targetLanguage": "German",
          "thisKeyDoesNotExist": 123,
          "neitherDoesThis": {"nested": ["a", "b"]},
          "andThisOneIsNull": null
        }
        """)
        var expected = Settings()
        expected.targetLanguage = "German"
        #expect(settings == expected)
    }

    // MARK: - Wrong types fall back per-field, independently of each other

    @Test func wrongTypedFieldsFallBackWithoutCorruptingSiblingFields() throws {
        // One JSON object mixing deliberately wrong types across several
        // different Swift types (String, Bool, Double, [String], an enum raw
        // value) with a couple of correctly-typed "control" fields between
        // them. If the per-field fallback were accidentally implemented as a
        // single `try?` around the *whole* decode instead of one per field,
        // every field -- including the well-typed ones -- would silently
        // revert to defaults, and this test would catch that.
        let settings = try decode("""
        {
          "elevenLabsAPIKey": 12345,
          "removeFillerWords": "yes please",
          "silenceSeconds": "soon",
          "commandTriggers": "not-an-array",
          "llmProvider": "chatgpt-5000",
          "maxRecordingSeconds": true,

          "targetLanguage": "Japanese",
          "anthropicModel": "claude-haiku-4-5"
        }
        """)

        let d = Settings()
        #expect(settings.elevenLabsAPIKey == d.elevenLabsAPIKey)
        #expect(settings.removeFillerWords == d.removeFillerWords)
        #expect(settings.silenceSeconds == d.silenceSeconds)
        #expect(settings.commandTriggers == d.commandTriggers)
        #expect(settings.llmProvider == d.llmProvider)
        #expect(settings.maxRecordingSeconds == d.maxRecordingSeconds)

        #expect(settings.targetLanguage == "Japanese")
        #expect(settings.anthropicModel == "claude-haiku-4-5")
    }

    @Test func invalidLLMProviderRawValueFallsBackToDefault() throws {
        let settings = try decode(#"{"llmProvider": "not-a-real-provider"}"#)
        #expect(settings.llmProvider == Settings().llmProvider)
    }

    @Test func invalidHotkeyModeRawValueFallsBackToDefault() throws {
        let settings = try decode(#"{"hotkeyMode": "byVoiceAlone"}"#)
        #expect(settings.hotkeyMode == Settings().hotkeyMode)
    }

    @Test func invalidSTTProviderRawValueFallsBackToDefault() throws {
        let settings = try decode(#"{"sttProvider": "carrier-pigeon"}"#)
        #expect(settings.sttProvider == Settings().sttProvider)
    }

    @Test func invalidHUDStyleRawValueFallsBackToDefault() throws {
        let settings = try decode(#"{"hudStyle": "holographic"}"#)
        #expect(settings.hudStyle == Settings().hudStyle)
    }

    @Test func glossaryOfWrongShapeFallsBackToEmpty() throws {
        let settings = try decode(#"{"glossary": {"canonical": "nginx"}}"#)
        #expect(settings.glossary == Settings().glossary)
    }

    // MARK: - The optional `sttLanguage` field

    @Test func sttLanguageAbsentIsNil() throws {
        #expect(try decode("{}").sttLanguage == nil)
    }

    @Test func sttLanguageExplicitNullIsNil() throws {
        #expect(try decode(#"{"sttLanguage": null}"#).sttLanguage == nil)
    }

    @Test func sttLanguageWrongTypeFallsBackToNilRatherThanThrowing() throws {
        // decodeIfPresent + `try?` + `?? nil`: a type mismatch here must not
        // take the rest of the file down with it.
        let settings = try decode(#"{"sttLanguage": 42, "targetLanguage": "Italian"}"#)
        #expect(settings.sttLanguage == nil)
        #expect(settings.targetLanguage == "Italian")
    }

    @Test func sttLanguageValidStringRoundTrips() throws {
        #expect(try decode(#"{"sttLanguage": "rus"}"#).sttLanguage == "rus")
    }

    // MARK: - A malformed glossary entry costs only itself

    @Test func oneMalformedGlossaryEntryDoesNotTakeTheRestWithIt() throws {
        // Regression: the array used to be decoded behind a single `try?`, so
        // one element missing the required `canonical` field discarded every
        // other term too. In a file meant to be hand-edited that is the worst
        // kind of failure -- total, and invisible.
        let settings = try decode("""
        {"glossary": [{"canonical": "nginx"}, {"heardAs": ["missing canonical"]}]}
        """)
        #expect(settings.glossary.count == 1)
        #expect(settings.glossary[0].canonical == "nginx")
    }

    @Test func wellFormedGlossaryDecodesInFull() throws {
        let settings = try decode("""
        {"glossary": [
          {"canonical": "Kubernetes", "heardAs": ["cuber netes"]},
          {"canonical": "PostgreSQL"}
        ]}
        """)
        #expect(settings.glossary.count == 2)
        #expect(settings.glossary[0].canonical == "Kubernetes")
        #expect(settings.glossary[0].heardAs == ["cuber netes"])
        #expect(settings.glossary[1].canonical == "PostgreSQL")
        #expect(settings.glossary[1].heardAs == [])
    }

    // MARK: - Genuinely broken JSON is a different failure mode

    @Test func truncatedJSONThrowsInsteadOfSilentlyLosingData() {
        // Per-field fallback only covers a well-formed *object* with a bad
        // value in one of its fields. A file that is not valid JSON at all --
        // e.g. a write that got cut off mid-save -- fails while parsing,
        // before `Settings.init(from:)` ever runs, and correctly throws
        // rather than returning some half-populated `Settings`.
        // `SettingsStore.loadFromDisk()` is what catches that and falls back
        // to a fresh `Settings()`; `Settings` itself does not swallow it,
        // which is what this pins down.
        let truncated = #"{"anthropicModel": "claude-haiku-4-5","#
        #expect(throws: (any Error).self) {
            try decode(truncated)
        }
    }

    @Test func topLevelJSONArrayInsteadOfObjectThrows() {
        #expect(throws: (any Error).self) {
            try decode("[]")
        }
    }

    // MARK: - GlossaryEntry's own decoding: canonical is required, heardAs is not

    @Test func glossaryEntryDefaultsHeardAsWhenMissing() throws {
        let entry = try JSONDecoder().decode(
            GlossaryEntry.self, from: Data(#"{"canonical": "nginx"}"#.utf8))
        #expect(entry.canonical == "nginx")
        #expect(entry.heardAs == [])
    }

    @Test func glossaryEntryMissingCanonicalThrows() {
        // Unlike every field of `Settings` itself, `GlossaryEntry.canonical`
        // has no fallback -- it is `try`, not `try?`. A glossary entry with
        // no canonical spelling is meaningless, so this is required to fail
        // rather than silently produce an empty-named entry.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GlossaryEntry.self, from: Data(#"{"heardAs": ["x"]}"#.utf8))
        }
    }
}
