import Foundation

/// A model LLM Gateway serves, as `GET /v1/models` lists it.
public struct LLMGatewayModel: Equatable {
    public var id: String
    public var name: String
    /// Who runs it: "openai", "anthropic", "google", "meta"…; "llmgateway" for its own routers.
    public var family: String
    /// Can call tools — the only kind that can run the home.
    public var tools: Bool
    /// Can look at photos.
    public var vision: Bool
    public var free: Bool

    public init(id: String, name: String, family: String, tools: Bool, vision: Bool, free: Bool) {
        self.id = id
        self.name = name
        self.family = family
        self.tools = tools
        self.vision = vision
        self.free = free
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        name = (json["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? json["name"] as? String ?? id
        family = json["family"] as? String ?? ""
        let providers = json["providers"] as? [[String: Any]] ?? []
        tools = providers.contains { $0["tools"] as? Bool == true }
        vision = providers.contains { $0["vision"] as? Bool == true }
            || ((json["architecture"] as? [String: Any])?["input_modalities"] as? [String] ?? []).contains("image")
        free = json["free"] as? Bool ?? false
    }

    public var json: [String: Any] {
        ["id": id, "name": name, "family": family, "tools": tools, "vision": vision, "free": free]
    }
}

/// What went wrong talking to LLM Gateway, in words for the user.
public struct LLMGatewayError: LocalizedError, Equatable {
    public let status: Int
    public let message: String
    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
    public var errorDescription: String? { message }
}

/// LLM Gateway (llmgateway.io): one API key and one OpenAI-compatible endpoint in front of
/// every model — GPT, Claude, Gemini, Llama, DeepSeek, Mistral and the rest.
///
///     GET  /v1/models            every model, with what it can do
///     POST /v1/chat/completions  OpenAI chat completions, tools included
public final class LLMGatewayClient {
    public static let defaultBaseURL = URL(string: "https://api.llmgateway.io/v1")!
    /// The model that picks a model: LLM Gateway's own router.
    public static let defaultModel = "auto"

    public let baseURL: URL
    public var apiKey: String
    private let session: URLSession

    public init(apiKey: String, baseURL: URL = LLMGatewayClient.defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    /// A key looks like `llmgtwy_…`; anything else is a paste gone wrong.
    nonisolated public static func looksLikeKey(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 20 && key.count <= 200 && !key.contains(" ")
    }

    /// Every model that can call tools, so it can run the home. The list is public: it works
    /// without a key too.
    public func models() async throws -> [LLMGatewayModel] {
        let json = try await request("GET", "models", body: nil)
        return (json["data"] as? [[String: Any]] ?? []).compactMap(LLMGatewayModel.init(json:)).filter(\.tools)
    }

    /// One chat completion. `body` is the OpenAI request (`model`, `messages`, `tools`…);
    /// the answer is the completion as LLM Gateway returned it.
    public func complete(_ body: [String: Any]) async throws -> [String: Any] {
        try await request("POST", "chat/completions", body: body)
    }

    private func request(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("HouseControl (+\(About.source.absoluteString))", forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMGatewayError(status: 0, message: "LLM Gateway could not be reached: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw LLMGatewayError(status: status, message: Self.describe(status: status, json: json, data: data))
        }
        guard let json else { throw LLMGatewayError(status: status, message: "LLM Gateway answered with something that is not JSON.") }
        return json
    }

    private static func describe(status: Int, json: [String: Any]?, data: Data) -> String {
        let detail = (json?["error"] as? [String: Any])?["message"] as? String
            ?? json?["error"] as? String
            ?? json?["message"] as? String
            ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch status {
        case 401, 403: return "LLM Gateway did not accept the API key. Check it at llmgateway.io."
        case 402: return "The LLM Gateway account has no credits left. Top up at llmgateway.io."
        case 429: return "LLM Gateway is rate-limiting this key. Wait a moment and try again."
        default: return detail.isEmpty ? "LLM Gateway answered \(status)." : detail
        }
    }
}
