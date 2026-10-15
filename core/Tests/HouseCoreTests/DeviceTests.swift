import XCTest
@testable import HouseCore

@MainActor
final class DeviceTests: XCTestCase {
    private func json(_ commands: [[String: Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: commands, options: [.sortedKeys]), encoding: .utf8)!
    }

    func testHubWithoutSmartLifeSimulatesItsLinks() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = DeviceHub(directory: dir, secret: { _ in MemorySecretStore() })
        hub.setLinks(from: ["lights": [["id": "a", "tuya": ["deviceId": "dev1"]]]])
        XCTAssertNil(hub.cloud)
        XCTAssertEqual(hub.linkedDeviceCount, 0)
        XCTAssertNil(hub.servicesInfo["smartlife"])
        var reply: [String: Any]?
        hub.command(["id": "a", "kind": "light", "patch": ["on": true]]) { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, true)
    }

    func testPlanStoreKeepsSyncedBytesAndRevision() throws {
        let data = Data("{\n  \"name\": \"Synced\",\n  \"rooms\": []\n}".utf8)
        XCTAssertNoThrow(try PlanStore.validate(data))
        XCTAssertThrowsError(try PlanStore.validate(Data("{\"name\":\"x\"}".utf8)))
        XCTAssertEqual(PlanStore.revision(of: data).count, 16)
        XCTAssertNotEqual(PlanStore.revision(of: data), PlanStore.revision(of: data + Data(" ".utf8)))
    }

    func testSecretStores() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let file = FileSecretStore(url: url)
        XCTAssertNil(file.read())
        file.write(Data("secret".utf8))
        XCTAssertEqual(file.read(), Data("secret".utf8))
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertNotNil(file.stamp)
        file.write(nil)
        XCTAssertNil(file.read())
    }
}
