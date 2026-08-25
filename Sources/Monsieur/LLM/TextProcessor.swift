import Foundation

enum LLMError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case emptyResponse
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): return "No \(provider) API key. Add one in Settings."
        case .http(let code, let body):
            let snippet = body.prefix(300)
            return "\(code) from the model API: \(snippet)"
        case .emptyResponse: return "The model returned nothing."
        case .refused(let reason): return "The model declined: \(reason)"
        }
    }
}

protocol TextProcessor {
    /// Returns the finished text, ready to type.
    func process(_ request: PromptBuilder.Request) async throws -> String
}

enum ProcessorFactory {
    static func make(for settings: Settings) -> TextProcessor? {
        switch settings.llmProvider {
        case .none:
            return nil
        case .openai:
            return OpenAIProcessor(
                apiKey: settings.openAIAPIKey,
                model: settings.openAIModel,
                reasoningEffort: settings.openAIReasoningEffort)
        case .anthropic:
            return AnthropicProcessor(
                apiKey: settings.anthropicAPIKey,
                model: settings.anthropicModel,
                effort: settings.anthropicEffort)
        case .openrouter:
            return OpenAIProcessor(
                apiKey: settings.openRouterAPIKey,
                model: settings.openRouterModel,
                // OpenRouter routes to many backends, most of which reject an
                // unknown parameter outright; leave effort to the model.
                reasoningEffort: "",
                endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                // Optional, but it is how OpenRouter attributes traffic, and
                // being identifiable is the polite default.
                extraHeaders: [
                    "HTTP-Referer": "https://github.com/monsieur",
                    "X-Title": "Monsieur",
                ],
                providerName: "OpenRouter")
        }
    }
}

// MARK: - Shared transport

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // These are non-streaming requests, and a long dictation produces a
        // long rewrite: a minute is not enough headroom.
        config.timeoutIntervalForRequest = 240
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Posts JSON and returns the parsed object, or throws `LLMError.http`.
    static func postJSON(url: URL,
                         headers: [String: String],
                         body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.emptyResponse
        }
        return object
    }
}
