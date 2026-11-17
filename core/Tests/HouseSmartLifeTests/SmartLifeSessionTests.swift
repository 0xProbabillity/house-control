import XCTest
import HouseCore
@testable import HouseSmartLife

/// The Smart Life session against a fake gateway that checks signatures the way Tuya's
/// does: every request is signed with a key derived from the refresh token, so a client
/// holding a token the gateway has rotated away gets "sign invalid" (-9999999).
@MainActor
final class SmartLifeSessionTests: XCTestCase {
    private typealias T = SmartLifeService.Transport

    /// The gateway's side: the one refresh token it accepts, and what it was asked.
    @MainActor
    private final class Gateway {
        var refreshToken: String
        var accessToken = "access-0"
        var generation = 0
        var refreshes = 0
        var commands = 0

        init(refreshToken: String) { self.refreshToken = refreshToken }

        func answer(_ request: URLRequest) async throws -> [String: Any] {
            // Let other requests in flight interleave, as real network calls do.
            await Task.yield()
            let header = { (name: String) in request.value(forHTTPHeaderField: name) ?? "" }
            let rid = header("X-requestId")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "encdata" }?.value ?? ""
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["encdata"] as? String ?? ""
            let hashKey = T.md5Hex(rid + refreshToken)
            let headers = ["X-appKey", "X-requestId", "X-sid", "X-time", "X-token"].map { ($0, header($0)) }
            guard T.sign(hashKey: hashKey, headers: headers, query: query, body: body) == header("X-sign") else {
                return ["success": false, "code": -9999999, "msg": "sign invalid"]
            }
            let secret = T.secret(requestId: rid, hashKey: hashKey)
            let path = request.url!.path
            let result: Any
            if path.hasPrefix("/v1.0/m/token/") {
                refreshes += 1
                generation += 1
                refreshToken = "refresh-\(generation)"
                accessToken = "access-\(generation)"
                result = ["accessToken": accessToken, "refreshToken": refreshToken, "expireTime": 7200, "uid": "u"]
            } else {
                guard header("X-token") == accessToken else { return ["success": false, "code": 1010, "msg": "token invalid"] }
                commands += 1
                result = true
            }
            let plain = String(data: try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]), encoding: .utf8)!
            return ["success": true, "result": try T.encrypt(plain, secret: secret)]
        }
    }

    private func session(refresh: String, access: String = "access-0", expiresIn seconds: Double = 3600) -> SmartLifeService.Session {
        .init(userCode: "abc1234", accessToken: access, refreshToken: refresh,
              expiresAt: (Date().timeIntervalSince1970 + seconds) * 1000, uid: "u",
              endpoint: "https://gateway.test", username: "me@example.com")
    }

    private func vault(_ s: SmartLifeService.Session) -> MemorySecretStore {
        MemorySecretStore(try! JSONEncoder().encode(s))
    }

    private func service(_ vault: SecretStore, _ gateway: Gateway) -> SmartLifeService {
        let service = SmartLifeService(vault: vault)
        service.fetch = { try await gateway.answer($0) }
        return service
    }

    private let on: [[String: Any]] = [["code": "switch_1", "value": true]]

    /// A widget refreshed the token after this process read it: the command is retried with
    /// what the Keychain holds now and goes through.
    func testPicksUpATokenAnotherProcessRotated() async throws {
        let gateway = Gateway(refreshToken: "refresh-0")
        let store = vault(session(refresh: "refresh-0"))
        let app = service(store, gateway)
        XCTAssertTrue(app.isConfigured)

        gateway.refreshToken = "refresh-widget"
        gateway.accessToken = "access-widget"
        store.write(try JSONEncoder().encode(session(refresh: "refresh-widget", access: "access-widget")))

        try await app.send(on, to: "lamp")
        XCTAssertEqual(gateway.commands, 1)
        XCTAssertFalse(app.isExpired)
    }

    /// The access token was refused but the refresh token still works: one refresh, then the command.
    func testRefreshesWhenTheAccessTokenIsRefused() async throws {
        let gateway = Gateway(refreshToken: "refresh-0")
        gateway.accessToken = "access-new"
        let app = service(vault(session(refresh: "refresh-0")), gateway)
        try await app.send(on, to: "lamp")
        XCTAssertEqual(gateway.refreshes, 1)
        XCTAssertEqual(gateway.commands, 1)
    }

    /// The gateway no longer knows the refresh token at all: the error says to sign in again
    /// (not "sign invalid"), the session is marked expired, and a working request clears it.
    func testADeadSessionAsksForANewLogin() async throws {
        let gateway = Gateway(refreshToken: "refresh-elsewhere")
        let store = vault(session(refresh: "refresh-0"))
        let app = service(store, gateway)
        var changes: [Bool] = []
        app.onExpiredChange = { changes.append($0) }

        do {
            try await app.send(on, to: "lamp")
            XCTFail("a dead session must not succeed")
        } catch {
            XCTAssertEqual(error.localizedDescription, SmartLifeService.expiredMessage)
            XCTAssertEqual(tuyaCode(of: error), "-9999999")
        }
        XCTAssertTrue(app.isExpired)
        XCTAssertEqual(app.publicInfo["expired"] as? Bool, true)
        XCTAssertEqual(changes, [true])
        XCTAssertEqual(gateway.commands, 0)
        // Persisted: a widget or the next launch sees it too.
        XCTAssertTrue(service(store, gateway).isExpired)

        // Should the token come back to life (another process's login), the flag goes away.
        gateway.refreshToken = "refresh-0"
        try await app.send(on, to: "lamp")
        XCTAssertFalse(app.isExpired)
        XCTAssertEqual(changes, [true, false])
    }

    /// Several commands at once with an expired access token: one refresh for all of them,
    /// and none goes out signed with the token that refresh just rotated away.
    func testConcurrentRequestsShareOneRefresh() async throws {
        let gateway = Gateway(refreshToken: "refresh-0")
        let app = service(vault(session(refresh: "refresh-0", expiresIn: -10)), gateway)
        async let a: Void = app.send(on, to: "lamp-a")
        async let b: Void = app.send(on, to: "lamp-b")
        async let c: Void = app.send(on, to: "lamp-c")
        _ = try await (a, b, c)
        XCTAssertEqual(gateway.refreshes, 1)
        XCTAssertEqual(gateway.commands, 3)
        XCTAssertFalse(app.isExpired)
    }

    /// The app and a widget (two clients on one stored session, guarded by one lock file)
    /// both find the token expired: only one refreshes, the other takes the result.
    func testTwoProcessesRefreshOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = FileSecretStore(url: dir.appendingPathComponent("smartlife.json"))
        file.write(try JSONEncoder().encode(session(refresh: "refresh-0", expiresIn: -10)))
        XCTAssertEqual(file.lockURL?.lastPathComponent, "smartlife.json.lock")

        let gateway = Gateway(refreshToken: "refresh-0")
        let app = service(file, gateway)
        let widget = service(FileSecretStore(url: dir.appendingPathComponent("smartlife.json")), gateway)
        async let a: Void = app.send(on, to: "lamp")
        async let b: Void = widget.send(on, to: "lamp")
        _ = try await (a, b)
        XCTAssertEqual(gateway.refreshes, 1)
        XCTAssertEqual(gateway.commands, 2)
    }

    func testFileLockIsExclusiveUntilReleased() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        let acquired = await FileLock.acquire(url)
        let first = try XCTUnwrap(acquired)
        let blocked = await FileLock.acquire(url, timeout: 0.3)
        XCTAssertNil(blocked)
        first.release()
        let second = await FileLock.acquire(url, timeout: 0.3)
        XCTAssertNotNil(second)
        XCTAssertEqual(KeychainSecretStore(service: "s", account: "smartlife", lockDirectory: URL(fileURLWithPath: "/tmp/g")).lockURL?.path,
                       "/tmp/g/.smartlife.lock")
        XCTAssertNil(KeychainSecretStore(service: "s", account: "smartlife").lockURL)
    }
}
