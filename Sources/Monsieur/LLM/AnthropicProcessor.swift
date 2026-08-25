import Foundation

struct AnthropicProcessor: TextProcessor {
    let apiKey: String
    let model: String
    /// "low" / "medium" / "high" / "xhigh" / "max", or empty to omit.
    /// Low effort matters here: this is a latency-critical path sitting between
    /// the user finishing a sentence and text appearing at their cursor.
    let effort: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func process(_ request: PromptBuilder.Request) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingKey("Anthropic") }

        // The output is roughly as long as the input, so a fixed ceiling
        // truncates long dictations -- half an hour of speech is ~25k
        // characters. Scale with the transcript and keep a generous cap.
        let estimated = request.user.count / 2
        let maxTokens = min(32_000, max(4_000, estimated))

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
        ]
        if !effort.isEmpty {
            body["output_config"] = ["effort": effort]
        }

        let headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
        var object: [String: Any]
        do {
            object = try await HTTP.postJSON(url: Self.endpoint, headers: headers, body: body)
        } catch LLMError.http(400, let message) where body["output_config"] != nil {
            // Older models do not know about output_config.effort.
            Log.llm.info("retrying without output_config: \(message.prefix(120), privacy: .public)")
            body.removeValue(forKey: "output_config")
            object = try await HTTP.postJSON(url: Self.endpoint, headers: headers, body: body)
        }

        // A refusal comes back as HTTP 200 with stop_reason "refusal", so it has
        // to be checked explicitly before reading the content.
        if let stop = object["stop_reason"] as? String, stop == "refusal" {
            let details = object["stop_details"] as? [String: Any]
            let category = (details?["category"] as? String) ?? "unspecified"
            throw LLMError.refused(category)
        }

        if let stop = object["stop_reason"] as? String, stop == "max_tokens" {
            Log.llm.error("output hit max_tokens (\(maxTokens, privacy: .public)) — result is truncated")
        }
        guard let content = object["content"] as? [[String: Any]] else {
            throw LLMError.emptyResponse
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return PromptBuilder.cleanOutput(text)
    }
}
