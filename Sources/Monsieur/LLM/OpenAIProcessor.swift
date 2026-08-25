import Foundation

struct OpenAIProcessor: TextProcessor {
    let apiKey: String
    let model: String
    /// "minimal" / "low" / "medium" / "high", or empty to omit the parameter.
    let reasoningEffort: String
    /// OpenRouter serves the same chat-completions dialect, so it is this
    /// processor pointed at a different host rather than a second one.
    var endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    var extraHeaders: [String: String] = [:]
    var providerName = "OpenAI"

    func process(_ request: PromptBuilder.Request) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingKey(providerName) }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
        ]
        if !reasoningEffort.isEmpty {
            body["reasoning_effort"] = reasoningEffort
        }

        var headers = ["Authorization": "Bearer \(apiKey)"]
        headers.merge(extraHeaders) { current, _ in current }
        var object: [String: Any]
        do {
            object = try await HTTP.postJSON(url: endpoint, headers: headers, body: body)
        } catch LLMError.http(400, let message) where body["reasoning_effort"] != nil {
            // Non-reasoning models reject the parameter outright. Drop it and retry.
            Log.llm.info("retrying without reasoning_effort: \(message.prefix(120), privacy: .public)")
            body.removeValue(forKey: "reasoning_effort")
            object = try await HTTP.postJSON(url: endpoint, headers: headers, body: body)
        }

        guard let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw LLMError.emptyResponse }

        return PromptBuilder.cleanOutput(content)
    }
}
