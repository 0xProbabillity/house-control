import Foundation

/// What the home itself does for an AI: lists its tools, runs them, writes the guide.
/// On the Mac this is the panel's web UI, which owns the state of every device.
@MainActor
public protocol AgentBackend: AnyObject {
    /// `request["op"]` is `tools`, `call`, `guide` or `link`; see `web/src/agent/tools.js`.
    func agentRequest(_ request: [String: Any]) async throws -> [String: Any]
}

/// What an AI may do through the link.
public struct AgentPermissions: Equatable {
    /// Lights, air conditioners and scenes.
    public var control: Bool
    /// The floor plan: rooms, furniture, devices, scenes.
    public var edit: Bool

    public init(control: Bool = true, edit: Bool = true) {
        self.control = control
        self.edit = edit
    }

    var json: [String: Any] { ["control": control, "edit": edit] }
}

/// One line of the activity feed the user watches while an AI has access.
public struct AgentActivity {
    public var date: Date
    /// "ChatGPT", "Claude", "Cursor"… or "AI agent" when it does not say.
    public var client: String
    public var title: String
    public var ok: Bool
    /// True for reads (the guide, the state): the feed shows them quietly.
    public var quiet: Bool

    public init(date: Date = Date(), client: String, title: String, ok: Bool = true, quiet: Bool = false) {
        self.date = date
        self.client = client
        self.title = title
        self.ok = ok
        self.quiet = quiet
    }

    public var json: [String: Any] {
        ["time": date.timeIntervalSince1970 * 1000, "client": client, "title": title, "ok": ok, "quiet": quiet]
    }
}

/// The AI gateway: everything an AI can reach, behind one secret path segment.
///
///     /<token>/                  the guide: plain text an AI reads to learn the home (GET)
///     /<token>/do/<action…>      actions as plain links, for chat assistants that can only open links (GET)
///     /<token>/mcp               Model Context Protocol, Streamable HTTP with JSON responses (POST)
///     /<token>/api/tools         the same tools as JSON (GET), run with POST /api/call or /api/<tool>
///     /<token>/openapi.json      an OpenAPI description of /api, for GPT actions and agent frameworks
///
/// Anything without the token gets a plain 404, the same as a path that does not exist.
@MainActor
public final class AgentGateway {
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let version = "1.0"

    public weak var backend: AgentBackend?
    public private(set) var token: String
    public var permissions = AgentPermissions()
    /// The address the AI uses, e.g. `https://xyz.trycloudflare.com` or `http://127.0.0.1:7419`.
    public var publicBase = ""
    public var onActivity: ((AgentActivity) -> Void)?

    /// Names of MCP clients by session, as they introduced themselves.
    private var sessions: [String: String] = [:]
    private var recent: [Date] = []
    /// Requests per minute before the gateway answers 429.
    public var rateLimit = 240

    public init(token: String = AgentGateway.makeToken()) {
        self.token = token
    }

    /// 128 random bits, URL-safe.
    nonisolated public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return SyncPairing.base64URL(Data(bytes))
    }

    public func rotateToken() {
        token = Self.makeToken()
        sessions = [:]
    }

    public var linkURL: String { "\(publicBase)/\(token)" }
    public var mcpURL: String { "\(publicBase)/\(token)/mcp" }

    // MARK: - Routing

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // Link checkers ask with HEAD first: the same answer as GET, without the body.
        // Action links never run for HEAD.
        if request.method == "HEAD" {
            var get = request
            get.method = "GET"
            if get.path.split(separator: "/").dropFirst().first == "do" { get.path = get.path.components(separatedBy: "/do/").first ?? get.path }
            var response = await handle(get)
            response.headers["Content-Length"] = String(response.body.count)
            response.body = Data()
            return response
        }
        var segments = request.path.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).removingPercentEncoding ?? String($0)
        }
        if request.method == "GET", segments == ["robots.txt"] {
            // The guide is fetched by chat assistants on the user's request; it is never indexed (X-Robots-Tag).
            return .text("User-agent: *\nAllow: /\n")
        }
        guard let first = segments.first, Self.same(first, token) else {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return .notFound
        }
        segments.removeFirst()
        guard admit() else { return .text("Too many requests. Wait a minute.\n", status: 429) }
        let client = clientName(request)

        switch (request.method, segments.first ?? "") {
        case ("GET", ""), ("GET", "guide"), ("GET", "llms.txt"):
            return await guide(client: client)
        case ("GET", "do"):
            return await linkAction(Array(segments.dropFirst()), client: client)
        case ("POST", "mcp"):
            return await mcp(request, client: client)
        case ("GET", "mcp"):
            // No server-initiated stream: every answer comes back as JSON.
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"], body: Data())
        case ("DELETE", "mcp"):
            if let id = request.headers["mcp-session-id"] { sessions[id] = nil }
            return HTTPResponse(status: 204)
        case ("GET", "api") where segments.count == 2 && segments[1] == "tools":
            return await restTools()
        case ("POST", "api") where segments.count == 2:
            return await restCall(segments[1], request, client: client)
        case ("GET", "openapi.json"):
            return await openAPI()
        case ("GET", "plan.json"):
            return await restCall("get_floor_plan", HTTPRequest(method: "POST", path: ""), client: client)
        default:
            return .notFound
        }
    }

    /// Compares without leaking where the first difference is.
    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private func admit() -> Bool {
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0) > 60 }
        guard recent.count < rateLimit else { return false }
        recent.append(now)
        return true
    }

    /// Who is asking, as well as it can be told: the name an MCP client gave, or its user agent.
    func clientName(_ request: HTTPRequest) -> String {
        if let session = request.headers["mcp-session-id"], let name = sessions[session] { return name }
        return Self.friendlyName(request.headers["user-agent"] ?? "")
    }

    nonisolated public static func friendlyName(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("claude-code") || s.contains("claude code") { return "Claude Code" }
        if s.contains("chatgpt") || s.contains("openai") { return "ChatGPT" }
        if s.contains("claude") || s.contains("anthropic") { return "Claude" }
        if s.contains("cursor") { return "Cursor" }
        if s.contains("perplexity") { return "Perplexity" }
        if s.contains("gemini") || s.contains("google") { return "Gemini" }
        if s.contains("copilot") || s.contains("vscode") || s.contains("visual studio") { return "Copilot" }
        if s.contains("mistral") || s.contains("le chat") { return "Le Chat" }
        if s.contains("grok") || s.contains("xai") { return "Grok" }
        if s.contains("inspector") { return "MCP Inspector" }
        return "AI agent"
    }

    private func record(_ client: String, _ title: String, ok: Bool = true, quiet: Bool = false) {
        onActivity?(AgentActivity(date: Date(), client: client, title: title, ok: ok, quiet: quiet))
    }

    // MARK: - Backend

    private func ask(_ request: [String: Any]) async throws -> [String: Any] {
        guard let backend else { throw GatewayError("House Control is not ready yet. Try again in a moment.") }
        var request = request
        request["permissions"] = permissions.json
        request["base"] = linkURL
        return try await backend.agentRequest(request)
    }

    struct GatewayError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func tools() async throws -> [[String: Any]] {
        try await ask(["op": "tools"])["tools"] as? [[String: Any]] ?? []
    }

    /// Runs one tool. The answer has `content` (MCP content blocks), `isError` and `summary`.
    private func call(_ tool: String, _ arguments: [String: Any], client: String) async -> [String: Any] {
        do {
            let result = try await ask(["op": "call", "tool": tool, "arguments": arguments, "client": client])
            if let summary = result["summary"] as? String, !summary.isEmpty {
                record(client, summary, ok: !(result["isError"] as? Bool ?? false), quiet: result["quiet"] as? Bool ?? false)
            }
            return result
        } catch {
            record(client, "\(tool) failed: \(error.localizedDescription)", ok: false)
            return ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true]
        }
    }

    // MARK: - Guide and plain links

    private func guide(client: String) async -> HTTPResponse {
        do {
            let result = try await ask(["op": "guide"])
            record(client, "Read the guide", quiet: true)
            return .text(result["text"] as? String ?? "", type: "text/markdown; charset=utf-8")
        } catch {
            return .text("House Control is not ready: \(error.localizedDescription)\n", status: 503)
        }
    }

    private func linkAction(_ path: [String], client: String) async -> HTTPResponse {
        do {
            let result = try await ask(["op": "link", "path": path, "client": client])
            if let summary = result["summary"] as? String, !summary.isEmpty {
                record(client, summary, ok: result["ok"] as? Bool ?? true)
            }
            return .text(result["text"] as? String ?? "", status: result["status"] as? Int ?? 200,
                         type: "text/markdown; charset=utf-8")
        } catch {
            return .text("House Control is not ready: \(error.localizedDescription)\n", status: 503)
        }
    }

    // MARK: - REST

    private func restTools() async -> HTTPResponse {
        do {
            return .json(["tools": try await tools()])
        } catch {
            return .json(["error": error.localizedDescription], status: 503)
        }
    }

    private func restCall(_ name: String, _ request: HTTPRequest, client: String) async -> HTTPResponse {
        var tool = name
        var arguments: [String: Any] = [:]
        if !request.body.isEmpty {
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return .json(["error": "The body must be a JSON object."], status: 400)
            }
            arguments = json
        }
        if name == "call" {
            guard let named = arguments["tool"] as? String else {
                return .json(["error": "POST /api/call takes {\"tool\": \"…\", \"arguments\": {…}}."], status: 400)
            }
            tool = named
            arguments = arguments["arguments"] as? [String: Any] ?? [:]
        }
        let result = await call(tool, arguments, client: client)
        let failed = result["isError"] as? Bool ?? false
        var body: [String: Any] = ["ok": !failed]
        let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        body["result"] = texts.joined(separator: "\n\n")
        if let image = (result["content"] as? [[String: Any]] ?? []).first(where: { $0["type"] as? String == "image" }),
           let data = image["data"] as? String, let type = image["mimeType"] as? String {
            body["image"] = "data:\(type);base64,\(data)"
        }
        if let data = result["structuredContent"] { body["data"] = data }
        return .json(body, status: failed ? 400 : 200)
    }

    private func openAPI() async -> HTTPResponse {
        do {
            let tools = try await tools()
            var paths: [String: Any] = [:]
            for tool in tools {
                guard let name = tool["name"] as? String else { continue }
                paths["/api/\(name)"] = [
                    "post": [
                        "operationId": name,
                        "summary": tool["title"] ?? name,
                        "description": tool["description"] ?? "",
                        "requestBody": ["required": false, "content": ["application/json": ["schema": tool["inputSchema"] ?? ["type": "object"]]]],
                        "responses": ["200": ["description": "Done", "content": ["application/json": ["schema": [
                            "type": "object",
                            "properties": ["ok": ["type": "boolean"], "result": ["type": "string"], "data": ["type": "object"]],
                        ]]]]],
                    ] as [String: Any],
                ]
            }
            return .json([
                "openapi": "3.1.0",
                "info": ["title": "House Control", "version": Self.version,
                         "description": "Control the lights and air conditioners of a home and edit its 3D floor plan. Read GET / (the guide) first."],
                "servers": [["url": linkURL]],
                "paths": paths,
            ])
        } catch {
            return .json(["error": error.localizedDescription], status: 503)
        }
    }

    // MARK: - MCP

    private func mcp(_ request: HTTPRequest, client: String) async -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(Self.rpcError(nil, -32700, "Parse error"), status: 400)
        }
        var newSession: String?
        func one(_ message: [String: Any]) async -> [String: Any]? {
            let id = message["id"]
            guard let method = message["method"] as? String else {
                return id == nil ? nil : Self.rpcError(id, -32600, "Invalid request")
            }
            let params = message["params"] as? [String: Any] ?? [:]
            guard id != nil, !(id is NSNull) else { return nil } // a notification
            switch method {
            case "initialize":
                let info = params["clientInfo"] as? [String: Any]
                let raw = [info?["title"], info?["name"]].compactMap { $0 as? String }.first ?? ""
                var name = raw.isEmpty ? client : Self.friendlyName(raw)
                if name == "AI agent", !raw.isEmpty { name = raw }
                let session = UUID().uuidString.lowercased()
                sessions[session] = name
                newSession = session
                record(name, "Connected", quiet: true)
                let asked = params["protocolVersion"] as? String ?? ""
                let instructions = (try? await ask(["op": "instructions"]))?["text"] as? String ?? ""
                return Self.rpcResult(id, [
                    "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "house-control", "title": "House Control", "version": Self.version],
                    "instructions": instructions,
                ])
            case "ping":
                return Self.rpcResult(id, [:])
            case "tools/list":
                do {
                    return Self.rpcResult(id, ["tools": try await tools()])
                } catch {
                    return Self.rpcError(id, -32603, error.localizedDescription)
                }
            case "tools/call":
                guard let name = params["name"] as? String else { return Self.rpcError(id, -32602, "Missing tool name") }
                let caller = newSession.flatMap { sessions[$0] } ?? client
                var result = await call(name, params["arguments"] as? [String: Any] ?? [:], client: caller)
                result["summary"] = nil
                result["quiet"] = nil
                return Self.rpcResult(id, result)
            case "resources/list":
                return Self.rpcResult(id, ["resources": []])
            case "resources/templates/list":
                return Self.rpcResult(id, ["resourceTemplates": []])
            case "prompts/list":
                return Self.rpcResult(id, ["prompts": []])
            default:
                return Self.rpcError(id, -32601, "Method not found: \(method)")
            }
        }

        var headers = ["Content-Type": "application/json"]
        let replies: Any?
        if let batch = json as? [[String: Any]] {
            var out: [[String: Any]] = []
            for message in batch { if let reply = await one(message) { out.append(reply) } }
            replies = out.isEmpty ? nil : out
        } else if let message = json as? [String: Any] {
            replies = await one(message)
        } else {
            return .json(Self.rpcError(nil, -32600, "Invalid request"), status: 400)
        }
        if let newSession { headers["Mcp-Session-Id"] = newSession }
        guard let replies else { return HTTPResponse(status: 202, headers: headers) }
        let data = (try? JSONSerialization.data(withJSONObject: replies, options: [.withoutEscapingSlashes])) ?? Data()
        return HTTPResponse(status: 200, headers: headers, body: data)
    }

    static func rpcResult(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    static func rpcError(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}
