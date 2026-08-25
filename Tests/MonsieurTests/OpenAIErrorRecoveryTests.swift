import Testing
@testable import Monsieur

/// The realtime session can refuse an individual setting while staying open.
/// Recognising that from the message is what lets a recording carry on instead
/// of being abandoned, and it is pure string matching -- the part most likely
/// to rot when the wording changes.
@Suite("OpenAI session error recovery")
struct OpenAIErrorRecoveryTests {

    @Test func recognisesTheRefusalSeenInProduction() {
        #expect(OpenAIRealtimeClient.rejectedField(
            in: "The 'languages' parameter is not supported for this model.") == "languages")
    }

    @Test(arguments: [
        "The 'keywords' parameter is not supported for this model.",
        "Unknown parameter: 'keywords'.",
        "The \"keywords\" parameter is not supported.",
    ])
    func recognisesOtherPhrasingsAndQuoting(message: String) {
        #expect(OpenAIRealtimeClient.rejectedField(in: message) == "keywords")
    }

    @Test func ignoresErrorsThatAreNotAboutAField() {
        // Dropping a field in response to these would lose a setting for no
        // reason and hide the real problem.
        #expect(OpenAIRealtimeClient.rejectedField(in: "Invalid API key provided.") == nil)
        #expect(OpenAIRealtimeClient.rejectedField(in: "Rate limit reached.") == nil)
        #expect(OpenAIRealtimeClient.rejectedField(
            in: "Model \"gpt-4o-transcribe\" is a transcription model and cannot be used as the realtime session model.") == nil)
    }

    @Test func ignoresAFieldItDoesNotKnowHowToDropSafely() {
        // Only fields the payload builder can actually omit are recognised;
        // anything else has to surface as a real failure.
        #expect(OpenAIRealtimeClient.rejectedField(
            in: "The 'model' parameter is not supported.") == nil)
    }
}
