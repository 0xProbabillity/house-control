import XCTest
@testable import HouseCore

@MainActor
final class DeviceTests: XCTestCase {
    private func json(_ commands: [[String: Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: commands, options: [.sortedKeys]), encoding: .utf8)!
    }

    func testInfraredACCommands() {
        let ir: Set<String> = ["PowerOn", "PowerOff", "T", "M", "F"]
        XCTAssertEqual(json(TuyaMapper.acCommands(patch: ["on": true, "mode": "heat", "target": 24.0], link: [:], codes: ir)),
                       #"[{"code":"PowerOn","value":"PowerOn"},{"code":"M","value":1},{"code":"T","value":24}]"#)
        XCTAssertEqual(json(TuyaMapper.acCommands(patch: ["fan": "high"], link: [:], codes: ir)), #"[{"code":"F","value":3}]"#)
    }

    func testBulbCommandsUseTheDeviceRanges() {
        let bulb: Set<String> = ["switch_led", "work_mode", "bright_value_v2", "temp_value_v2", "colour_data_v2"]
        let ranges: TuyaMapper.Ranges = ["bright_value_v2": (10, 1000), "temp_value_v2": (0, 1000)]
        XCTAssertEqual(json(TuyaMapper.lightCommands(patch: ["on": true, "brightness": 0.5], state: [:], link: [:], codes: bulb, ranges: ranges)),
                       #"[{"code":"switch_led","value":true},{"code":"bright_value_v2","value":505}]"#)
        XCTAssertEqual(json(TuyaMapper.lightCommands(patch: ["on": true], state: [:], link: [:], codes: [])),
                       #"[{"code":"switch_1","value":true}]"#)
        let state = TuyaMapper.lightState(from: [["code": "switch_led", "value": true], ["code": "bright_value_v2", "value": 505.0]], ranges: ranges)
        XCTAssertEqual(state["on"] as? Bool, true)
        XCTAssertEqual(state["brightness"] as? Double ?? 0, 0.5, accuracy: 0.001)
    }

    func testInfraredRemoteReplaysStateAfterARefusedKey() async {
        let lines = await SelfTest.infraredTranscript()
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines[0].contains("kept for the next switch-on"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("→ ok") && lines[1].contains("PowerOn=PowerOn") && lines[1].contains("F=3"), lines[1])
        XCTAssertTrue(lines[2].contains("T=25 ✗") && lines[2].contains("M=0") && lines[2].hasSuffix("→ ok"), lines[2])
        XCTAssertTrue(lines[4].contains("rejected [\"target\"]"), lines[4])
        XCTAssertTrue(lines[5].contains("PowerOff=PowerOff"), lines[5])
    }

    func testTransportEnvelopeMatchesTheReferenceSDK() throws {
        typealias T = SmartLifeService.Transport
        let rid = "11111111-2222-3333-4444-555555555555"
        let hashKey = T.md5Hex(rid + "refresh-token")
        let secret = T.secret(requestId: rid, hashKey: hashKey)
        let cipher = try T.encrypt("{\"homeId\":\"42\"}", secret: secret, nonce: "ABCDEFGHJKMN")
        XCTAssertEqual(try T.decrypt(cipher, secret: secret), "{\"homeId\":\"42\"}")
        XCTAssertEqual(secret.count, 16)
    }

    func testHubSimulatesUnlinkedDevicesAndReadsLinks() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = DeviceHub(directory: dir, session: MemorySecretStore())
        hub.setLinks(from: ["lights": [["id": "a", "tuya": ["deviceId": "dev1"]], ["id": "b"], ["id": "c", "tuya": ["deviceId": ""]]],
                            "acs": [["id": "ac", "tuya": ["deviceId": "dev2", "sensorId": "s1"]]]])
        XCTAssertEqual(hub.linkedDeviceCount, 2)
        XCTAssertFalse(hub.isConnected)
        XCTAssertFalse(hub.canPoll)
        var reply: [String: Any]?
        hub.command(["id": "a", "kind": "light", "patch": ["on": true]]) { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, true) // not signed in: nothing is sent anywhere
        hub.setLinks(from: nil)
        XCTAssertFalse(hub.hasLinks)
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
