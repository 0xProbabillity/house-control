import Foundation

/// Talking to the home from inside the app: the user types, a model on LLM Gateway answers,
/// and runs the same tools an MCP client gets — through the `AgentBackend`, so the panel
/// and the activity feed see it like any other assistant.
///
///     user ─▶ HomeChat ─▶ api.llmgateway.io (any model) ─▶ tool calls ─▶ AgentBackend ─▶ the home
///
/// One conversation lives in memory; `clear()` starts over. Nothing is stored.
@MainActor
public final class HomeChat {
    /// One line of the conversation as the window shows it.
    public struct Entry: Equatable {
        public enum Role: String { case user, assistant }
        /// A tool the model ran while answering.
        public struct Step: Equatable {
            public var title: String
            public var ok: Bool
            /// A `data:` URL when the tool drew a picture (`render_home`).
            public var image: String?
        }
        public var role: Role
        public var text: String
        /// How many photos the user attached.
        public var photos: Int = 0
        public var steps: [Step] = []
        public var error: String?
        public var date = Date()

        public var json: [String: Any] {
            var out: [String: Any] = ["role": role.rawValue, "text": text, "photos": photos, "time": date.timeIntervalSince1970 * 1000,
                                      "steps": steps.map { step -> [String: Any] in
                                          var s: [String: Any] = ["title": step.title, "ok": step.ok]
                                          if let image = step.image { s["image"] = image }
                                          return s
                                      }]
            if let error { out["error"] = error }
            return out
        }
    }

    /// How the feed names it. The model's own name is in the step titles.
    public static let clientName = "LLM Gateway"
    /// Tool rounds for one message before the model is asked to wrap up (it gets no tools
    /// from then on); three times that, and a model that keeps calling anyway is cut off.
    public static let maxRounds = 12
    /// How much of a tool's answer the model gets; the home's overview fits several times over.
    static let maxToolText = 24_000
    /// Older turns fall off the model's context, not off the screen.
    static let maxHistory = 60

    public weak var backend: AgentBackend?
    public var permissions = AgentPermissions()
    public var client: LLMGatewayClient?
    public var model = LLMGatewayClient.defaultModel
    public var onActivity: ((AgentActivity) -> Void)?
    /// Fires whenever the transcript or `busy` changes.
    public var onChange: (() -> Void)?

    public private(set) var transcript: [Entry] = []
    public private(set) var busy = false
    /// The conversation as the model sees it (OpenAI messages, without the system prompt).
    private var history: [[String: Any]] = []
    /// Bumped by `clear()`: a turn still running then belongs to a conversation that is gone,
    /// and writes nothing more.
    private var generation = 0

    public init() {}

    public var isConfigured: Bool { !(client?.apiKey.isEmpty ?? true) }

    /// Starts over. A turn in flight keeps running the tool it is on, but its answer is dropped.
    public func clear() {
        generation += 1
        transcript = []
        history = []
        busy = false
        onChange?()
    }

    /// Sends one message. `photos` are `data:image/…;base64,…` URLs the user attached.
    /// Returns when the model has answered (or failed); the transcript grows along the way.
    public func send(_ text: String, photos: [String] = []) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty || !photos.isEmpty else { return }
        guard let client, isConfigured else {
            transcript.append(Entry(role: .assistant, text: "", error: "Add your LLM Gateway API key first."))
            onChange?()
            return
        }
        busy = true
        let turn = generation
        transcript.append(Entry(role: .user, text: text, photos: photos.count))
        var reply = Entry(role: .assistant, text: "")
        transcript.append(reply)
        let at = transcript.count - 1
        onChange?()
        /// Shows the reply as it stands — unless the conversation was cleared meanwhile.
        func show() {
            guard turn == generation, at < transcript.count else { return }
            transcript[at] = reply
            onChange?()
        }
        defer {
            if turn == generation { busy = false }
            show()
        }

        var content: Any = text
        if !photos.isEmpty {
            var parts: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
            for photo in photos { parts.append(["type": "image_url", "image_url": ["url": photo]]) }
            content = parts
        }
        let before = history
        history.append(["role": "user", "content": content])

        do {
            let tools = try await toolDefinitions()
            let system = try await systemPrompt()
            var rounds = 0
            while true {
                // Nothing goes to LLM Gateway for a conversation that was cleared while the
                // home was being asked for its tools, or while a tool ran.
                guard turn == generation else { return }
                var body: [String: Any] = ["model": model, "messages": [["role": "system", "content": system]] + history]
                if !tools.isEmpty, rounds < Self.maxRounds {
                    body["tools"] = tools
                    body["tool_choice"] = "auto"
                }
                let completion = try await client.complete(body)
                guard turn == generation else { return }
                guard let message = ((completion["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else {
                    throw LLMGatewayError(status: 0, message: "The model sent back an empty answer.")
                }
                history.append(Self.assistantMessage(message))
                trimHistory()
                let calls = message["tool_calls"] as? [[String: Any]] ?? []
                if calls.isEmpty {
                    reply.text = Self.text(of: message["content"])
                    if reply.text.isEmpty { reply.text = reply.steps.isEmpty ? "(The model had nothing to say.)" : "Done." }
                    break
                }
                rounds += 1
                if rounds > Self.maxRounds * 3 {
                    throw LLMGatewayError(status: 0, message: "The model kept calling tools without finishing. Try again, or another model.")
                }
                for call in calls {
                    let id = call["id"] as? String ?? UUID().uuidString
                    let function = call["function"] as? [String: Any] ?? [:]
                    let name = function["name"] as? String ?? ""
                    let arguments = Self.arguments(function["arguments"])
                    let (result, step) = await run(name, arguments)
                    guard turn == generation else { return }
                    reply.steps.append(step)
                    show()
                    history.append(["role": "tool", "tool_call_id": id, "content": result])
                }
            }
        } catch {
            guard turn == generation else { return }
            reply.error = error.localizedDescription
            // A failed turn must not poison the next one: the model never saw it.
            history = before
        }
    }

    // MARK: - The home's side

    private func ask(_ request: [String: Any]) async throws -> [String: Any] {
        guard let backend else { throw LLMGatewayError(status: 0, message: "House Control is not ready yet. Try again in a moment.") }
        var request = request
        request["permissions"] = permissions.json
        request["base"] = ""
        request["client"] = Self.clientName
        return try await backend.agentRequest(request)
    }

    /// The home's tools in OpenAI's shape.
    func toolDefinitions() async throws -> [[String: Any]] {
        let tools = try await ask(["op": "tools"])["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            var function: [String: Any] = ["name": name, "parameters": tool["inputSchema"] ?? ["type": "object"]]
            let description = [tool["title"] as? String, tool["description"] as? String].compactMap { $0 }.joined(separator: ". ")
            if !description.isEmpty { function["description"] = description }
            return ["type": "function", "function": function]
        }
    }

    private func systemPrompt() async throws -> String {
        let instructions = (try? await ask(["op": "instructions"]))?["text"] as? String ?? ""
        return instructions + "\n\nYou are talking to the owner inside the House Control app on their Mac, not through a link. "
            + "Answer in plain text (no Markdown headings), in one or two short sentences, unless they ask for detail. "
            + "A picture from render_home is shown to the owner next to your answer; you do not need to describe it. "
            + "Today is \(Self.today())."
    }

    private func run(_ name: String, _ arguments: [String: Any]) async -> (String, Entry.Step) {
        do {
            let result = try await ask(["op": "call", "tool": name, "arguments": arguments])
            let failed = result["isError"] as? Bool ?? false
            let content = result["content"] as? [[String: Any]] ?? []
            var text = content.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            if text.count > Self.maxToolText { text = String(text.prefix(Self.maxToolText)) + "\n…(cut)" }
            var step = Entry.Step(title: result["summary"] as? String ?? (failed ? "\(name) failed" : name), ok: !failed)
            if let image = content.first(where: { $0["type"] as? String == "image" }),
               let data = image["data"] as? String, let type = image["mimeType"] as? String {
                step.image = "data:\(type);base64,\(data)"
                if text.isEmpty { text = "The picture was rendered and is shown to the owner." }
            }
            if result["quiet"] as? Bool != true || failed {
                onActivity?(AgentActivity(client: Self.clientName, title: step.title, ok: step.ok, quiet: result["quiet"] as? Bool ?? false))
            }
            return (text.isEmpty ? "Done." : text, step)
        } catch {
            onActivity?(AgentActivity(client: Self.clientName, title: "\(name) failed: \(error.localizedDescription)", ok: false))
            return ("Error: \(error.localizedDescription)", Entry.Step(title: "\(name) failed: \(error.localizedDescription)", ok: false))
        }
    }

    // MARK: - Shapes

    /// What the model said, kept for the next turn: its text and its tool calls, nothing else.
    static func assistantMessage(_ message: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["role": "assistant", "content": message["content"] ?? NSNull()]
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            out["tool_calls"] = calls.map { call -> [String: Any] in
                let function = call["function"] as? [String: Any] ?? [:]
                return ["id": call["id"] ?? UUID().uuidString, "type": "function",
                        "function": ["name": function["name"] ?? "", "arguments": function["arguments"] as? String ?? "{}"]]
            }
        }
        return out
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// Tool arguments arrive as a JSON string (OpenAI) or, from some models, already parsed.
    static func arguments(_ raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        guard let s = raw as? String, let data = s.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Drops the oldest turns once the conversation is long. A cut lands on a user message
    /// only, so a tool answer never loses the call it belongs to; if the last turns alone are
    /// over the limit, nothing goes.
    func trimHistory() {
        guard history.count > Self.maxHistory else { return }
        var cut = history.count - Self.maxHistory
        while cut < history.count, (history[cut]["role"] as? String) != "user" { cut += 1 }
        guard cut > 0, cut < history.count else { return }
        history.removeFirst(cut)
    }

    /// For tests: what the model would be sent next.
    var modelHistory: [[String: Any]] { history }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: Date())
    }
}
