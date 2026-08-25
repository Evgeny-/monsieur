import Foundation
import Testing

@testable import Monsieur

/// Assertions here deliberately check for *presence* of glossary entries,
/// trigger words, the nonce tags, etc. rather than pinning down the full
/// prose of the system prompt verbatim. The prompt is a hand-tuned Swift
/// multi-line string literal (see `PromptBuilder.system`), and line breaks
/// inside it are real `\n` characters wherever the source wraps a line
/// without a trailing `\` continuation -- a test asserting an exact sentence
/// that happens to straddle one of those wraps would be pinning
/// implementation formatting, not behaviour.
struct PromptBuilderRequestTests {

    // MARK: - Nonce wrapping

    @Test func transcriptIsWrappedInMatchingNonceTags() throws {
        let request = PromptBuilder.build(transcript: "hello world", settings: Settings(), appName: nil)

        let openEnd = try #require(request.user.firstIndex(of: ">"))
        let openTag = String(request.user[..<openEnd]) + ">"
        let nonce = openTag
            .replacingOccurrences(of: "<transcript-", with: "")
            .replacingOccurrences(of: ">", with: "")

        #expect(nonce.count == 8)
        #expect(nonce.allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) })
        #expect(request.user == "\(openTag)\nhello world\n</transcript-\(nonce)>")

        // The system prompt tells the model which tag to expect -- it must
        // name the exact same nonce the user message actually uses, or the
        // model has no way to know where the untrusted data starts and ends.
        #expect(request.system.contains("<transcript-\(nonce)>"))
    }

    @Test func twoBuildsProduceDifferentNonces() {
        let a = PromptBuilder.build(transcript: "x", settings: Settings(), appName: nil)
        let b = PromptBuilder.build(transcript: "x", settings: Settings(), appName: nil)
        #expect(a.user != b.user)
    }

    // MARK: - Glossary

    @Test func glossaryEntriesAppearInSystemPrompt() {
        var settings = Settings()
        settings.glossary = [
            GlossaryEntry(canonical: "Kubernetes", heardAs: ["cuber netes"]),
            GlossaryEntry(canonical: "nginx"),
        ]
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(request.system.contains("Kubernetes"))
        #expect(request.system.contains("cuber netes"))
        #expect(request.system.contains("nginx"))
        #expect(request.system.contains("# Glossary"))
    }

    @Test func emptyGlossaryOmitsTheGlossarySection() {
        var settings = Settings()
        settings.glossary = []
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(!request.system.contains("# Glossary"))
    }

    @Test func glossaryEntryWithEmptyCanonicalIsFilteredOut() {
        var settings = Settings()
        settings.glossary = [GlossaryEntry(canonical: "", heardAs: ["orphaned mishearing"])]
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(!request.system.contains("# Glossary"))
        #expect(!request.system.contains("orphaned mishearing"))
    }

    @Test func glossaryEntryWithoutHeardAsOmitsTheParenthetical() {
        var settings = Settings()
        settings.glossary = [GlossaryEntry(canonical: "PostgreSQL")]
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(request.system.contains("- PostgreSQL\n"))
        #expect(!request.system.contains("often heard as"))
    }

    @Test func glossaryEntryWithHeardAsIncludesTheParenthetical() {
        var settings = Settings()
        settings.glossary = [GlossaryEntry(canonical: "PostgreSQL", heardAs: ["post gres", "postgres"])]
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(request.system.contains("- PostgreSQL  (often heard as: post gres, postgres)"))
    }

    // MARK: - Trigger words

    @Test func triggerWordsAppearInSystemPrompt() {
        var settings = Settings()
        settings.commandTriggers = ["слушай", "команда", "custom-trigger"]
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        for trigger in settings.commandTriggers {
            #expect(request.system.contains(trigger))
        }
        // Built the same way `PromptBuilder` builds it, rather than a
        // hand-copied phrase that could drift from a harmless prose edit.
        let expectedList = settings.commandTriggers.map { "\"\($0)\"" }.joined(separator: ", ")
        #expect(request.system.contains(expectedList))
    }

    @Test func emptyCommandTriggersOmitTheTriggerSentence() {
        var settings = Settings()
        settings.commandTriggers = []
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(!request.system.contains("trigger"))
    }

    @Test func emptyStringTriggersAreFilteredOut() {
        var settings = Settings()
        settings.commandTriggers = ["", "real-trigger"]
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(request.system.contains("\"real-trigger\""))
        #expect(!request.system.contains("\"\""))
    }

    @Test func detectUntriggeredCommandsTogglesThatParagraph() {
        var settings = Settings()
        settings.detectUntriggeredCommands = true
        let on = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(on.system.contains("unmistakably an aside"))

        settings.detectUntriggeredCommands = false
        let off = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(!off.system.contains("unmistakably an aside"))
    }

    // MARK: - Custom instructions

    @Test func customInstructionsAppearWhenPresent() {
        var settings = Settings()
        settings.customInstructions = "Always sign off with my name."
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(request.system.contains("Always sign off with my name."))
        #expect(request.system.contains("# Standing preferences"))
    }

    @Test func whitespaceOnlyCustomInstructionsOmitTheSection() {
        var settings = Settings()
        settings.customInstructions = "   \n  "
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(!request.system.contains("# Standing preferences"))
    }

    // MARK: - App name / context

    @Test func appNameAppearsWhenProvided() {
        let request = PromptBuilder.build(transcript: "x", settings: Settings(), appName: "Slack")
        #expect(request.system.contains("# Context"))
        #expect(request.system.contains("Slack"))
    }

    @Test func nilAppNameOmitsContextSection() {
        let request = PromptBuilder.build(transcript: "x", settings: Settings(), appName: nil)
        #expect(!request.system.contains("# Context"))
    }

    @Test func emptyAppNameOmitsContextSection() {
        let request = PromptBuilder.build(transcript: "x", settings: Settings(), appName: "")
        #expect(!request.system.contains("# Context"))
    }

    // MARK: - Target language

    @Test func targetLanguageAppearsInTheOutputContract() {
        var settings = Settings()
        settings.targetLanguage = "French"
        let request = PromptBuilder.build(transcript: "x", settings: settings, appName: nil)
        #expect(request.system.contains("Return only the finished text, in French."))
    }
}

/// `cleanOutput` undoes the two ways a model tends to ignore the "no
/// preamble, no code fence, no surrounding quotes" instruction in the output
/// contract, without mangling text that only superficially resembles either.
struct PromptBuilderCleanOutputTests {

    @Test func stripsAPlainCodeFence() {
        #expect(PromptBuilder.cleanOutput("```\nHello world\n```") == "Hello world")
    }

    @Test func stripsAFencedBlockWithALanguageTag() {
        // The whole first line -- fence *and* language annotation -- is
        // dropped, not just the leading backticks.
        #expect(PromptBuilder.cleanOutput("```swift\nlet x = 1\n```") == "let x = 1")
    }

    @Test func stripsAMultiLineFencedBlock() {
        #expect(PromptBuilder.cleanOutput("```\nline one\nline two\n```") == "line one\nline two")
    }

    @Test func leavesUnfencedTextAlone() {
        #expect(PromptBuilder.cleanOutput("Hello world") == "Hello world")
    }

    @Test func stripsQuotesWrappingTheWholeString() {
        #expect(PromptBuilder.cleanOutput("\"Hello world\"") == "Hello world")
    }

    @Test func leavesInnerQuotesThatDoNotWrapTheWholeStringAlone() {
        let text = "She said \"hello\" to me"
        #expect(PromptBuilder.cleanOutput(text) == text)
    }

    @Test func refusesToStripOuterQuotesWhenAnInnerQuoteIsAlsoPresent() {
        // Source comment: "Only strip quotes that wrap the whole thing and
        // appear nowhere else." A quote anywhere in the middle aborts the
        // strip entirely -- it does not strip the outer pair and leave the
        // inner one, which is what makes this worth pinning down.
        let text = "\"quoted\" and more\""
        #expect(PromptBuilder.cleanOutput(text) == text)
    }

    @Test func aLoneQuoteCharacterIsLeftAlone() {
        #expect(PromptBuilder.cleanOutput("\"") == "\"")
    }

    @Test func emptyStringStaysEmpty() {
        #expect(PromptBuilder.cleanOutput("") == "")
    }

    @Test func fenceAndWrappingQuotesBothStripInOnePass() {
        #expect(PromptBuilder.cleanOutput("```\n\"Hello world\"\n```") == "Hello world")
    }

    @Test func trimsSurroundingWhitespaceAndNewlines() {
        #expect(PromptBuilder.cleanOutput("\n\n  Hello world  \n\n") == "Hello world")
    }
}
