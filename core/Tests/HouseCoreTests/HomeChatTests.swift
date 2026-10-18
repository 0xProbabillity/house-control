import XCTest
@testable import HouseCore

/// Plays LLM Gateway: answers `URLSession` requests from a script, and keeps what was asked.
private final class FakeGateway: URLProtocol {
    nonisolated(unsafe) static var replies: [(status: Int, body: [String: Any])] = []
    nonisolated(unsafe) static var requests: [(url: String, headers: [String: String], body: [String: Any]?)] = []
    /// Seconds each answer takes to arrive.
    nonisolated(unsafe) static var delay: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body: [String: Any]?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else if let data = request.httpBody {
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        Self.requests.append((request.url?.absoluteString ?? "", request.allHTTPHeaderFields ?? [:], body))
        let reply = Self.replies.isEmpty ? (status: 500, body: ["error": ["message": "no scripted reply"]]) : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = try! JSONSerialization.data(withJSONObject: reply.body)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// The home as the chat sees it: two tools, and a lamp that remembers whether it was switched.
@MainActor
private final class FakeHome: AgentBackend {
    var calls: [(tool: String, arguments: [String: Any], client: String)] = []
    var lampOn = false

    func agentRequest(_ request: [String: Any]) async throws -> [String: Any] {
        switch request["op"] as? String {
        case "tools":
            let permissions = request["permissions"] as? [String: Any] ?? [:]
            var tools: [[String: Any]] = [["name": "get_home", "title": "Look at the home", "description": "Every room and device.", "inputSchema": ["type": "object", "properties": [:]]]]
            if permissions["control"] as? Bool != false {
                tools.append(["name": "set_lights", "title": "Lights", "description": "On, off, brightness.",
                              "inputSchema": ["type": "object", "properties": ["lights": ["type": "array"], "on": ["type": "boolean"]]]])
            }
            return ["tools": tools]
        case "instructions":
            return ["text": "Call get_home first."]
        case "call":
            let tool = request["tool"] as? String ?? ""
            let arguments = request["arguments"] as? [String: Any] ?? [:]
            calls.append((tool, arguments, request["client"] as? String ?? ""))
            if tool == "set_lights" {
                lampOn = arguments["on"] as? Bool ?? false
                return ["content": [["type": "text", "text": "Living · Lamp: \(lampOn ? "on" : "off")"]], "isError": false, "summary": lampOn ? "On: Lamp" : "Off: Lamp"]
            }
            if tool == "render_home" {
                return ["content": [["type": "image", "data": "AAAA", "mimeType": "image/png"], ["type": "text", "text": "Rendered."]], "isError": false, "summary": "Rendered the home", "quiet": true]
            }
            return ["content": [["type": "text", "text": "Living: Lamp [living.lamp] off"]], "isError": false, "summary": "Looked at the home", "quiet": true]
        default:
            return [:]
        }
    }
}

@MainActor
final class HomeChatTests: XCTestCase {
    private var home: FakeHome!
    private var chat: HomeChat!
    private var activity: [AgentActivity] = []
    private var changes = 0

    override func setUp() async throws {
        FakeGateway.replies = []
        FakeGateway.requests = []
        FakeGateway.delay = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGateway.self]
        home = FakeHome()
        chat = HomeChat()
        chat.backend = home
        chat.client = LLMGatewayClient(apiKey: "llmgtwy_test_key_0123456789", session: URLSession(configuration: config))
        chat.model = "gpt-5-mini"
        activity = []
        changes = 0
        chat.onActivity = { [unowned self] in self.activity.append($0) }
        chat.onChange = { [unowned self] in self.changes += 1 }
    }

    private func completion(text: String?, calls: [(id: String, name: String, arguments: String)] = []) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": text ?? NSNull()]
        if !calls.isEmpty {
            message["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
        }
        return ["id": "chatcmpl-1", "choices": [["index": 0, "message": message, "finish_reason": calls.isEmpty ? "stop" : "tool_calls"]]]
    }

    private var sentBodies: [[String: Any]] { FakeGateway.requests.compactMap(\.body) }

    func testToolCallsRunTheHomeAndTheAnswerLandsInTheTranscript() async {
        FakeGateway.replies = [
            (200, completion(text: nil, calls: [("c1", "get_home", "{}")])),
            (200, completion(text: nil, calls: [("c2", "set_lights", #"{"lights": ["living.lamp"], "on": true}"#)])),
            (200, completion(text: "Done — the lamp is on.")),
        ]
        await chat.send("turn the lamp on")

        XCTAssertTrue(home.lampOn)
        XCTAssertEqual(home.calls.map(\.tool), ["get_home", "set_lights"])
        XCTAssertEqual(home.calls.last?.client, "LLM Gateway")
        XCTAssertEqual(chat.transcript.count, 2)
        XCTAssertEqual(chat.transcript[0].role, .user)
        XCTAssertEqual(chat.transcript[0].text, "turn the lamp on")
        let reply = chat.transcript[1]
        XCTAssertEqual(reply.text, "Done — the lamp is on.")
        XCTAssertEqual(reply.steps.map(\.title), ["Looked at the home", "On: Lamp"])
        XCTAssertTrue(reply.steps.allSatisfy(\.ok))
        XCTAssertNil(reply.error)
        XCTAssertFalse(chat.busy)
        // The quiet look is not in the feed; the switch is.
        XCTAssertEqual(activity.map(\.title), ["On: Lamp"])
        XCTAssertEqual(activity.first?.client, "LLM Gateway")
        XCTAssertGreaterThanOrEqual(changes, 4)

        // What LLM Gateway was sent: the key, the model, the tools, and the whole exchange.
        let first = FakeGateway.requests[0]
        XCTAssertEqual(first.url, "https://api.llmgateway.io/v1/chat/completions")
        XCTAssertEqual(first.headers["Authorization"], "Bearer llmgtwy_test_key_0123456789")
        XCTAssertEqual(first.body?["model"] as? String, "gpt-5-mini")
        let tools = first.body?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.map { ($0["function"] as? [String: Any])?["name"] as? String }, ["get_home", "set_lights"])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        let messages = first.body?["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertTrue((messages[0]["content"] as? String ?? "").hasPrefix("Call get_home first."))

        let third = sentBodies[2]["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(third.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "assistant", "tool"])
        XCTAssertEqual(third[3]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(third[5]["content"] as? String, "Living · Lamp: on")
        let callBack = (third[4]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any]
        XCTAssertEqual(callBack?["name"] as? String, "set_lights")
    }

    func testTheConversationCarriesOnAndAPhotoTravelsAsAnImage() async {
        FakeGateway.replies = [(200, completion(text: "Hello.")), (200, completion(text: "A sofa and a lamp."))]
        await chat.send("hi")
        await chat.send("what is in this room?", photos: ["data:image/jpeg;base64,/9j/4AAQ"])

        XCTAssertEqual(chat.transcript.count, 4)
        XCTAssertEqual(chat.transcript[2].photos, 1)
        let messages = sentBodies[1]["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        let parts = messages[3]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image_url"])
        XCTAssertEqual((parts[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/jpeg;base64,/9j/4AAQ")
    }

    func testARenderedPictureReachesTheTranscript() async {
        FakeGateway.replies = [
            (200, completion(text: nil, calls: [("c1", "render_home", "{}")])),
            (200, completion(text: "Here it is.")),
        ]
        await chat.send("show me the home")
        XCTAssertEqual(chat.transcript[1].steps.first?.image, "data:image/png;base64,AAAA")
        XCTAssertEqual(chat.transcript[1].text, "Here it is.")
    }

    func testAGatewayErrorIsShownAndDoesNotPoisonTheNextTurn() async {
        FakeGateway.replies = [(401, ["error": ["message": "Invalid API key"]])]
        await chat.send("hello")
        XCTAssertEqual(chat.transcript.count, 2)
        XCTAssertEqual(chat.transcript[1].error, "LLM Gateway did not accept the API key. Check it at llmgateway.io.")
        XCTAssertFalse(chat.busy)

        FakeGateway.replies = [(200, completion(text: "Hi again."))]
        await chat.send("hello again")
        let messages = sentBodies.last?["messages"] as? [[String: Any]] ?? []
        // The failed "hello" is gone from what the model sees.
        XCTAssertEqual(messages.map { $0["content"] as? String }, [messages[0]["content"] as? String, "hello again"])
        XCTAssertEqual(chat.transcript.last?.text, "Hi again.")
    }

    func testPermissionsLimitTheTools() async {
        chat.permissions = AgentPermissions(control: false, edit: true)
        FakeGateway.replies = [(200, completion(text: "I can only look."))]
        await chat.send("turn everything off")
        let tools = sentBodies[0]["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.map { ($0["function"] as? [String: Any])?["name"] as? String }, ["get_home"])
    }

    func testWithoutAKeyNothingIsSent() async {
        chat.client = nil
        await chat.send("hello")
        XCTAssertEqual(chat.transcript.last?.error, "Add your LLM Gateway API key first.")
        XCTAssertTrue(FakeGateway.requests.isEmpty)
    }

    func testClearStartsOver() async {
        FakeGateway.replies = [(200, completion(text: "Hello.")), (200, completion(text: "Fresh."))]
        await chat.send("hi")
        chat.clear()
        XCTAssertTrue(chat.transcript.isEmpty)
        await chat.send("again")
        let messages = sentBodies.last?["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 2)
    }

    func testClearWhileATurnIsRunningDropsThatTurn() async {
        FakeGateway.delay = 0.3
        // The model answers the first turn with a tool call — after the user has moved on.
        FakeGateway.replies = [
            (200, completion(text: nil, calls: [("c1", "set_lights", #"{"lights": ["living.lamp"], "on": true}"#)])),
            (200, completion(text: "Hello.")),
        ]
        let turn = Task { await self.chat.send("turn the lamp on") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(chat.busy)
        chat.clear()
        XCTAssertTrue(chat.transcript.isEmpty)
        XCTAssertFalse(chat.busy)

        // A new conversation starts at once, while the old turn is still waiting on the model.
        let next = Task { await self.chat.send("hello") }
        await turn.value
        await next.value
        XCTAssertEqual(chat.transcript.map(\.text), ["hello", "Hello."])
        XCTAssertFalse(chat.busy)
        XCTAssertEqual(chat.modelHistory.count, 2)
        // The abandoned turn neither ran its tool nor asked the model again.
        XCTAssertTrue(home.calls.isEmpty)
        XCTAssertEqual(FakeGateway.requests.count, 2)
    }

    func testOldTurnsFallOffTheModelsContextAtAUserMessage() async {
        for i in 0..<40 {
            FakeGateway.replies = [(200, completion(text: "Reply \(i)."))]
            await chat.send("Message \(i)")
        }
        let history = chat.modelHistory
        XCTAssertLessThanOrEqual(history.count, HomeChat.maxHistory)
        XCTAssertEqual(history.first?["role"] as? String, "user")
        XCTAssertEqual(history.first?["content"] as? String, "Message 10")
        XCTAssertEqual(chat.transcript.count, 80)
    }

    func testOneLongTurnIsNeverCutInTheMiddle() async {
        // More tool rounds in one turn than the limit has messages: none of them droppable.
        let rounds = HomeChat.maxHistory / 2 + 1
        var replies: [(status: Int, body: [String: Any])] = []
        for i in 0..<rounds { replies.append((200, completion(text: nil, calls: [("c\(i)", "get_home", "{}")]))) }
        replies.append((200, completion(text: "Looked \(rounds) times.")))
        FakeGateway.replies = replies
        await chat.send("look again and again")
        let history = chat.modelHistory
        XCTAssertEqual(history.count, 2 + 2 * rounds)
        XCTAssertEqual(history.first?["role"] as? String, "user")
        for (i, message) in history.enumerated() where message["role"] as? String == "tool" {
            XCTAssertNotNil(history[i - 1]["tool_calls"], "tool answer at \(i) has no call before it")
        }
        XCTAssertEqual(chat.transcript.last?.text, "Looked \(rounds) times.")
    }

    func testAModelThatNeverStopsCallingToolsIsCutOff() async {
        FakeGateway.replies = (0..<(HomeChat.maxRounds * 3 + 2)).map { i in (200, completion(text: nil, calls: [("c\(i)", "get_home", "{}")])) }
        await chat.send("loop")
        XCTAssertEqual(chat.transcript.last?.error, "The model kept calling tools without finishing. Try again, or another model.")
        XCTAssertEqual(FakeGateway.requests.count, HomeChat.maxRounds * 3 + 1)
        XCTAssertTrue(chat.modelHistory.isEmpty)
    }

    func testModelsListKeepsOnlyThoseThatCanCallTools() async throws {
        FakeGateway.replies = [(200, ["data": [
            ["id": "auto", "name": "Auto", "family": "llmgateway", "providers": [["providerId": "llmgateway", "tools": true, "vision": true]], "free": false],
            ["id": "gpt-5-mini", "display_name": "GPT-5 Mini", "family": "openai", "providers": [["providerId": "openai", "tools": true, "vision": true], ["providerId": "azure", "tools": true, "vision": false]]],
            ["id": "tts-1", "name": "TTS", "family": "openai", "providers": [["providerId": "openai", "tools": false, "vision": false]]],
            ["id": "llama", "name": "Llama", "family": "meta", "providers": [["providerId": "groq", "tools": true]], "free": true],
        ]])]
        let models = try await chat.client!.models()
        XCTAssertEqual(models.map(\.id), ["auto", "gpt-5-mini", "llama"])
        XCTAssertEqual(models[1].name, "GPT-5 Mini")
        XCTAssertTrue(models[1].vision)
        XCTAssertFalse(models[2].vision)
        XCTAssertTrue(models[2].free)
        XCTAssertEqual(FakeGateway.requests[0].url, "https://api.llmgateway.io/v1/models")
    }

    func testToolArgumentsComeAsAStringOrAnObject() {
        XCTAssertEqual(HomeChat.arguments(#"{"on": true}"#)["on"] as? Bool, true)
        XCTAssertEqual(HomeChat.arguments(["on": false])["on"] as? Bool, false)
        XCTAssertTrue(HomeChat.arguments("not json").isEmpty)
        XCTAssertTrue(HomeChat.arguments(nil).isEmpty)
    }
}
