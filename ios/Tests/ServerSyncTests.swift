import XCTest
import HouseCore
@testable import SharedServerSync

@MainActor final class ServerSyncTests: XCTestCase {
    private func plan(_ name: String) -> [String: Any] {
        // Valid minimal raw plan, same format the native editor saves.
        ["name": name, "rooms": [["id": "room", "name": "Room", "rect": [0, 0, 4, 4]]], "lights": [], "acs": [], "features": [], "furniture": []]
    }
    private func fixture(_ local: [String: Any]?, _ remote: [String: Any]) -> (ServerSync, Box) {
        let defaults = UserDefaults(suiteName: "sync-test-\(UUID().uuidString)")!
        defaults.set(true, forKey: "sharedServerEnabled")
        defaults.set("https://house.example", forKey: "sharedServerAddress")
        let sync = ServerSync(secret: MemorySecretStore(Data("token".utf8)), defaults: defaults)
        let box = Box(local: local, remote: remote)
        sync.local = { box.local }
        sync.adopt = { box.local = $0; box.adoptions += 1 }
        sync.backup = { box.backups.append($0) }
        sync.transport = { method, body in
            if method == "GET" { return ["config": box.remote, "revision": box.revision] }
            box.puts += 1
            XCTAssertEqual(body?["expectedRevision"] as? Int, box.revision)
            if box.stale { throw ServerSync.Failure("The server plan changed") }
            box.remote = body?["config"] as! [String: Any]; box.revision += 1
            return ["ok": true, "revision": box.revision]
        }
        return (sync, box)
    }
    func testInitialEmptyPhoneAdoptsServer() async {
        let (sync, box) = fixture(nil, plan("Server"))
        await sync.synchronize()
        XCTAssertEqual(box.local?["name"] as? String, "Server")
        XCTAssertEqual(box.adoptions, 1); XCTAssertEqual(box.puts, 0); XCTAssertFalse(sync.conflict)
    }
    func testUnchangedLocalRemoteAndSingleSideEdits() async {
        let (sync, box) = fixture(plan("Home"), plan("Home"))
        await sync.synchronize()
        XCTAssertEqual(box.puts, 0); XCTAssertEqual(box.adoptions, 0)
        box.local = plan("Phone edit")
        await sync.synchronize()
        XCTAssertEqual(box.remote["name"] as? String, "Phone edit"); XCTAssertEqual(box.puts, 1)
        box.remote = plan("Android edit"); box.revision += 1
        await sync.synchronize()
        XCTAssertEqual(box.local?["name"] as? String, "Android edit"); XCTAssertEqual(box.adoptions, 1)
    }
    func testBothChangedRequiresChoiceAndBacksUpDisplacedPlan() async {
        let (sync, box) = fixture(plan("Home"), plan("Home"))
        await sync.synchronize(); box.local = plan("Phone"); box.remote = plan("Android"); box.revision += 1
        await sync.synchronize()
        XCTAssertTrue(sync.conflict); XCTAssertEqual(box.puts, 0); XCTAssertEqual(box.adoptions, 0)
        await sync.resolve(keepPhone: true)
        XCTAssertEqual(box.backups.first?["name"] as? String, "Android")
        XCTAssertEqual(box.remote["name"] as? String, "Phone"); XCTAssertFalse(sync.conflict)
    }
    func testStalePutPreservesLocalAndShowsFailure() async {
        let (sync, box) = fixture(plan("Home"), plan("Home"))
        await sync.synchronize(); box.local = plan("Phone"); box.stale = true
        await sync.synchronize()
        XCTAssertTrue(sync.status.hasPrefix("Not synced:")); XCTAssertEqual(box.local?["name"] as? String, "Phone")
        XCTAssertEqual(box.remote["name"] as? String, "Home")
    }
    func testLocalEditDuringFetchDoesNotGetOverwritten() async {
        let (sync, box) = fixture(plan("Home"), plan("Home"))
        await sync.synchronize()
        sync.transport = { _, _ in
            box.local = self.plan("Edited while fetching")
            sync.localChanged()
            return ["config": self.plan("Android edit"), "revision": 2]
        }
        await sync.synchronize()
        XCTAssertTrue(sync.conflict); XCTAssertEqual(box.local?["name"] as? String, "Edited while fetching")
    }
    func testEditDuringPutQueuesAnotherRevisionWithoutLosingLocalWork() async {
        let (sync, box) = fixture(plan("Home"), plan("Home"))
        await sync.synchronize(); box.local = plan("First edit")
        var changed = false
        sync.transport = { method, body in
            if method == "GET" { return ["config": box.remote, "revision": box.revision] }
            XCTAssertEqual(body?["expectedRevision"] as? Int, box.revision)
            box.remote = body?["config"] as! [String: Any]; box.revision += 1; box.puts += 1
            if !changed { changed = true; box.local = self.plan("Second edit"); sync.localChanged() }
            return ["ok": true, "revision": box.revision]
        }
        await sync.synchronize()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(box.local?["name"] as? String, "Second edit")
        XCTAssertEqual(box.remote["name"] as? String, "Second edit")
        XCTAssertEqual(box.puts, 2)
    }
    func testRemoteEditWhileEditorOpenConflictsWithSavedDraft() async {
        let (sync, box) = fixture(plan("Home"), plan("Home"))
        await sync.synchronize(); sync.beginEditing()
        box.remote = plan("Android change"); box.revision += 1
        await sync.synchronize()
        XCTAssertEqual(box.local?["name"] as? String, "Home")
        box.local = plan("Phone draft")
        await sync.synchronize(publishingDraft: true)
        XCTAssertTrue(sync.conflict)
        XCTAssertEqual(box.remote["name"] as? String, "Android change")
        XCTAssertEqual(box.local?["name"] as? String, "Phone draft")
        XCTAssertEqual(box.puts, 0)
    }
    func testLocalModeStopsSyncAndNewOriginNeedsNewToken() async throws {
        let (sync, box) = fixture(plan("Phone"), plan("Server"))
        XCTAssertThrowsError(try sync.connect(address: "https://other.example", token: ""))
        XCTAssertEqual(sync.address, "https://house.example")
        sync.useMacMode(); await sync.synchronize()
        XCTAssertFalse(sync.enabled); XCTAssertEqual(box.puts, 0); XCTAssertEqual(box.adoptions, 0)
    }
    func testAddressPolicy() throws {
        for value in ["https://house.example", "http://192.168.1.2:8787", "http://house.local", "http://[::1]:8787"] { XCTAssertNoThrow(try ServerSync.validAddress(value)) }
        for value in ["http://example.com", "https://user:secret@example.com", "https://example.com/?token=secret", "file:///secret", "https://example.com/path"] { XCTAssertThrowsError(try ServerSync.validAddress(value)) }
    }
}
@MainActor private final class Box {
    var local: [String: Any]?
    var remote: [String: Any]
    var revision = 1
    var puts = 0
    var adoptions = 0
    var backups: [[String: Any]] = []
    var stale = false
    init(local: [String: Any]?, remote: [String: Any]) { self.local = local; self.remote = remote }
}
