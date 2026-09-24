import Foundation
import Testing
@testable import Monsieur

@Suite("ElevenLabs realtime glossary constraints")
struct ElevenLabsRequestTests {
    @Test func skipsTheTermThatRejectedTheWholeSession() throws {
        var settings = Settings()
        settings.glossary = [
            .init(canonical: "favicon", heardAs: ["фриконка"]),
            .init(canonical: "server-side rendering", heardAs: ["сервер Site Rendering"]),
            .init(canonical: "Claude Code"),
        ]
        let url = try ElevenLabsRealtimeClient.connectionURL(settings: settings)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.filter { $0.name == "keyterms" }.compactMap(\.value) == ["favicon", "Claude Code"])
        #expect(query.contains(URLQueryItem(name: "audio_format", value: "pcm_16000")))
        #expect(query.contains(URLQueryItem(name: "model_id", value: "scribe_v2_realtime")))
        // The service-specific limit must not shrink the persisted/LLM glossary.
        #expect(settings.glossary.count == 3)
        let prompt = PromptBuilder.build(transcript: "test", settings: settings, appName: nil)
        #expect(prompt.system.contains("server-side rendering"))
        #expect(prompt.system.contains("сервер Site Rendering"))
    }

    @Test func acceptsTwentyCharactersButNotTwentyOne() {
        let twenty = String(repeating: "a", count: 20)
        #expect(ElevenLabsRealtimeClient.keyterms(from: [
            .init(canonical: twenty), .init(canonical: twenty + "b"),
        ]) == [twenty])
    }

    @Test func countsUnicodeCodePointsNotUTF8BytesOrGraphemes() {
        let cyrillic = String(repeating: "я", count: 20)
        let combining = String(repeating: "e\u{0301}", count: 11)
        #expect(cyrillic.utf8.count == 40)
        #expect(combining.count == 11)
        #expect(combining.unicodeScalars.count == 22)
        #expect(ElevenLabsRealtimeClient.keyterms(from: [
            .init(canonical: cyrillic), .init(canonical: combining),
        ]) == [cyrillic])
    }

    @Test func trimsSkipsBlankTermsAndDeduplicatesWithoutConsumingSlots() {
        let glossary: [GlossaryEntry] = [
            .init(canonical: " "), .init(canonical: "\n"),
            .init(canonical: " Claude Code\n"), .init(canonical: "claude code"),
            .init(canonical: ".env"), .init(canonical: "all-hands"),
        ]
        #expect(ElevenLabsRealtimeClient.keyterms(from: glossary) == ["Claude Code", ".env", "all-hands"])
    }

    @Test func capsTheRequestAtFiftyValidUniqueTerms() {
        var glossary: [GlossaryEntry] = [.init(canonical: "server-side rendering")]
        for n in 0..<60 {
            glossary.append(.init(canonical: "term\(n)"))
            glossary.append(.init(canonical: "TERM\(n)"))
        }
        #expect(ElevenLabsRealtimeClient.keyterms(from: glossary) == (0..<50).map { "term\($0)" })
        #expect(glossary.count == 121)
    }

    @Test func preservesTheLanguageAndVerbatimOptions() throws {
        var settings = Settings()
        settings.sttLanguage = "rus"
        settings.removeFillerWords = false
        let url = try ElevenLabsRealtimeClient.connectionURL(settings: settings)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "language_code", value: "rus")))
        #expect(!query.contains { $0.name == "no_verbatim" })
    }
}

@Suite("ElevenLabs rejected sessions")
struct ElevenLabsSessionErrorTests {
    @Test func recognisesInvalidRequestWithoutAnErrorSuffix() {
        let message = "Each keyterm must be at most 20 characters. 'server-side rendering' is 21 characters."
        #expect(ElevenLabsRealtimeClient.serverErrorMessage(in: [
            "message_type": "invalid_request", "message": message,
        ]) == message)
    }

    @Test func supportsErrorFieldAndTypeOnlyResponses() {
        #expect(ElevenLabsRealtimeClient.serverErrorMessage(in: [
            "message_type": "invalid_request", "error": "bad options",
        ]) == "bad options")
        #expect(ElevenLabsRealtimeClient.serverErrorMessage(in: [
            "message_type": "auth_error",
        ]) == "auth_error")
        #expect(ElevenLabsRealtimeClient.serverErrorMessage(in: [
            "message_type": "session_time_limit_exceeded",
        ]) == "session_time_limit_exceeded")
    }

    @Test func doesNotTreatTranscriptTextAsAnError() {
        #expect(ElevenLabsRealtimeClient.serverErrorMessage(in: [
            "message_type": "partial_transcript", "text": "invalid_request error",
        ]) == nil)
    }

    @Test @MainActor func reportsTheServerRejectionAndPreservesCommittedText() async {
        let client = ElevenLabsRealtimeClient()
        var failures: [String] = []
        client.onEvent = { event in
            if case .failed(let error) = event { failures.append(error.localizedDescription) }
        }
        client.handle(#"{"message_type":"committed_transcript","text":"Already spoken"}"#)
        // Even text mentioning a session limit must remain terminal when the
        // event is invalid_request; retrying identical options will not help.
        client.handle(#"{"message_type":"invalid_request","message":"This session exceeds the keyterm limit."}"#)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(failures == ["This session exceeds the keyterm limit."])
        #expect(await client.finish(timeout: 0) == "Already spoken")
    }
}
