import XCTest
@testable import HouseCore

/// Stands in for the panel page: answers like `web/src/agent/tools.js` does.
@MainActor
private final class FakeHome: AgentBackend {
    var requests: [[String: Any]] = []

    func agentRequest(_ request: [String: Any]) async throws -> [String: Any] {
        requests.append(request)
        let permissions = request["permissions"] as? [String: Any] ?? [:]
        switch request["op"] as? String {
        case "tools":
            var tools: [[String: Any]] = [["name": "get_home", "title": "Look", "description": "d", "inputSchema": ["type": "object"]]]
            if permissions["control"] as? Bool != false {
                tools.append(["name": "set_lights", "title": "Lights", "description": "d", "inputSchema": ["type": "object"]])
            }
            return ["tools": tools]
        case "call":
            let tool = request["tool"] as? String ?? ""
            if tool == "set_lights" {
                let on = (request["arguments"] as? [String: Any])?["on"] as? Bool ?? false
                return ["content": [["type": "text", "text": on ? "Living · Lamp: on" : "Living · Lamp: off"]], "isError": false,
                        "summary": on ? "On: Lamp" : "Off: Lamp"]
            }
            return ["content": [["type": "text", "text": "Home with 1 lamp"]], "isError": false, "summary": "Looked", "quiet": true,
                    "structuredContent": ["home": "Test"]]
        case "guide":
            return ["text": "# House Control — Test\nbase \(request["base"] as? String ?? "")"]
        case "instructions":
            return ["text": "Call get_home first."]
        case "link":
            return ["text": "Done. \((request["path"] as? [String] ?? []).joined(separator: "/"))", "summary": "On: Lamp", "ok": true]
        default:
            return [:]
        }
    }
}

@MainActor
final class AgentTests: XCTestCase {
    private var home: FakeHome!
    private var gateway: AgentGateway!
    private var activity: [AgentActivity] = []

    override func setUp() async throws {
        home = FakeHome()
        gateway = AgentGateway(token: "secret-token")
        gateway.backend = home
        gateway.publicBase = "https://example.trycloudflare.com"
        activity = []
        gateway.onActivity = { [unowned self] in self.activity.append($0) }
    }

    private func json(_ response: HTTPResponse) -> Any? { try? JSONSerialization.jsonObject(with: response.body) }

    private func rpc(_ body: Any, session: String? = nil) async -> HTTPResponse {
        var headers = ["content-type": "application/json", "user-agent": "Claude-User"]
        if let session { headers["mcp-session-id"] = session }
        return await gateway.handle(HTTPRequest(method: "POST", path: "/secret-token/mcp", headers: headers,
                                                body: try! JSONSerialization.data(withJSONObject: body)))
    }

    func testEverythingWithoutTheTokenIsNotFound() async {
        for path in ["/", "/wrong-token", "/wrong-token/mcp", "/secret-tokenX/", "/SECRET-TOKEN/"] {
            let response = await gateway.handle(HTTPRequest(method: "GET", path: path))
            XCTAssertEqual(response.status, 404, path)
        }
        XCTAssertTrue(home.requests.isEmpty)
        let status3286 = await gateway.handle(HTTPRequest(method: "GET", path: "/robots.txt")).status
        XCTAssertEqual(status3286, 200)
    }

    func testGuideIsPlainTextWithTheLink() async {
        let response = await gateway.handle(HTTPRequest(method: "GET", path: "/secret-token", headers: ["user-agent": "Mozilla/5.0 ChatGPT-User/1.0"]))
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.headers["Content-Type"]?.hasPrefix("text/markdown") == true)
        XCTAssertTrue(String(data: response.body, encoding: .utf8)!.contains("base https://example.trycloudflare.com/secret-token"))
        XCTAssertEqual(activity.last?.client, "ChatGPT")
    }

    func testLinkActionsPassTheirPath() async {
        let response = await gateway.handle(HTTPRequest(method: "GET", path: "/secret-token/do/light/living.lamp/on"))
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "Done. light/living.lamp/on")
        XCTAssertEqual(activity.last?.title, "On: Lamp")
    }

    func testMCPHandshakeListAndCall() async throws {
        let initialize = await rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-ai", "version": "1"], "capabilities": [:]]])
        XCTAssertEqual(initialize.status, 200)
        let session = try XCTUnwrap(initialize.headers["Mcp-Session-Id"])
        let result = try XCTUnwrap((json(initialize) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(result["instructions"] as? String, "Call get_home first.")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "house-control")

        let note = await rpc(["jsonrpc": "2.0", "method": "notifications/initialized"], session: session)
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)

        let list = await rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: session)
        let tools = ((json(list) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["get_home", "set_lights"])

        let call = await rpc(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "set_lights", "arguments": ["lights": ["living"], "on": true]]],
                             session: session)
        let callResult = try XCTUnwrap((json(call) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(callResult["isError"] as? Bool, false)
        XCTAssertNil(callResult["summary"], "the feed's summary is not part of the MCP result")
        XCTAssertEqual(((callResult["content"] as? [[String: Any]])?.first)?["text"] as? String, "Living · Lamp: on")
        XCTAssertEqual(activity.last?.client, "Claude")
        XCTAssertEqual(activity.last?.title, "On: Lamp")
    }

    func testMCPUnknownMethodsAndBatches() async {
        let unknown = await rpc(["jsonrpc": "2.0", "id": 9, "method": "sampling/whatever"])
        XCTAssertEqual(((json(unknown) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let batch = await rpc([["jsonrpc": "2.0", "id": 1, "method": "ping"], ["jsonrpc": "2.0", "method": "notifications/initialized"],
                               ["jsonrpc": "2.0", "id": 2, "method": "prompts/list"]])
        XCTAssertEqual((json(batch) as? [[String: Any]])?.count, 2)
        let garbage = await gateway.handle(HTTPRequest(method: "POST", path: "/secret-token/mcp", body: Data("{nope".utf8)))
        XCTAssertEqual(garbage.status, 400)
        let status6969 = await gateway.handle(HTTPRequest(method: "GET", path: "/secret-token/mcp")).status
        XCTAssertEqual(status6969, 405)
    }

    func testPermissionsReachTheHome() async {
        gateway.permissions = AgentPermissions(control: false, edit: false)
        let list = await gateway.handle(HTTPRequest(method: "GET", path: "/secret-token/api/tools"))
        let tools = (json(list) as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual((home.requests.last?["permissions"] as? [String: Any])?["control"] as? Bool, false)
    }

    func testRESTCallAndOpenAPI() async {
        let call = await gateway.handle(HTTPRequest(method: "POST", path: "/secret-token/api/set_lights", body: Data(#"{"lights":["all"],"on":false}"#.utf8)))
        XCTAssertEqual(call.status, 200)
        XCTAssertEqual((json(call) as? [String: Any])?["result"] as? String, "Living · Lamp: off")
        let named = await gateway.handle(HTTPRequest(method: "POST", path: "/secret-token/api/call",
                                                     body: Data(#"{"tool":"get_home","arguments":{}}"#.utf8)))
        XCTAssertEqual(((json(named) as? [String: Any])?["data"] as? [String: Any])?["home"] as? String, "Test")
        let bad = await gateway.handle(HTTPRequest(method: "POST", path: "/secret-token/api/set_lights", body: Data("[1]".utf8)))
        XCTAssertEqual(bad.status, 400)
        let spec = await gateway.handle(HTTPRequest(method: "GET", path: "/secret-token/openapi.json"))
        let paths = (json(spec) as? [String: Any])?["paths"] as? [String: Any]
        XCTAssertNotNil(paths?["/api/set_lights"])
        XCTAssertEqual(((json(spec) as? [String: Any])?["servers"] as? [[String: Any]])?.first?["url"] as? String,
                       "https://example.trycloudflare.com/secret-token")
    }

    func testHeadNeverRunsAnAction() async {
        let head = await gateway.handle(HTTPRequest(method: "HEAD", path: "/secret-token/do/light/living.lamp/on"))
        XCTAssertEqual(head.status, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertFalse(home.requests.contains { $0["op"] as? String == "link" })
    }

    func testRateLimit() async {
        gateway.rateLimit = 3
        for _ in 0..<3 { _ = await gateway.handle(HTTPRequest(method: "GET", path: "/secret-token/do/state")) }
        let status8987 = await gateway.handle(HTTPRequest(method: "GET", path: "/secret-token/do/state")).status
        XCTAssertEqual(status8987, 429)
    }

    func testTokensAreLongAndFresh() {
        let a = AgentGateway.makeToken(), b = AgentGateway.makeToken()
        XCTAssertEqual(a.count, 22)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    func testClientNames() {
        XCTAssertEqual(AgentGateway.friendlyName("Mozilla/5.0 AppleWebKit/537.36; compatible; ChatGPT-User/1.0; +https://openai.com/bot"), "ChatGPT")
        XCTAssertEqual(AgentGateway.friendlyName("Claude-User (claude-code/2.1)"), "Claude Code")
        XCTAssertEqual(AgentGateway.friendlyName("openai-mcp"), "ChatGPT")
        XCTAssertEqual(AgentGateway.friendlyName("python-httpx/0.27"), "AI agent")
    }

    // MARK: - HTTP

    func testParserHandlesChunkedAndPipelinedRequests() {
        var buffer = Data(("POST /t/mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n"
            + "GET /t/ HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").utf8)
        guard case .request(let first, let keepAlive) = HTTPParser.parse(&buffer, maxBody: 1000) else { return XCTFail("first") }
        XCTAssertEqual(String(data: first.body, encoding: .utf8), "{\"a\":1}")
        XCTAssertTrue(keepAlive)
        guard case .request(let second, let keep2) = HTTPParser.parse(&buffer, maxBody: 1000) else { return XCTFail("second") }
        XCTAssertEqual(second.path, "/t/")
        XCTAssertFalse(keep2)
        XCTAssertTrue(buffer.isEmpty)

        var partial = Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345".utf8)
        guard case .incomplete = HTTPParser.parse(&partial, maxBody: 1000) else { return XCTFail("partial") }
        var huge = Data("POST / HTTP/1.1\r\nContent-Length: 99999\r\n\r\n".utf8)
        guard case .invalid(413) = HTTPParser.parse(&huge, maxBody: 1000) else { return XCTFail("huge") }
    }

    func testLoopbackServerEndToEnd() async throws {
        let server = LoopbackHTTPServer { [unowned self] in await self.gateway.handle($0) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.start(preferredPort: 0) { continuation.resume(with: $0) }
        }
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)/secret-token")!
        let (guide, response) = try await URLSession.shared.data(from: base)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: guide, encoding: .utf8)!.hasPrefix("# House Control"))

        var post = URLRequest(url: base.appendingPathComponent("mcp"))
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        post.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let (data, _) = try await URLSession.shared.data(for: post)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("set_lights"))

        let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/nope")!)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
    }
}
