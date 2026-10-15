import XCTest
import Network
@testable import HouseCore

private final class Flag { var isSet = false }

@MainActor
final class SyncTests: XCTestCase {
    func testPairingLinkRoundTrip() throws {
        let pairing = SyncPairing.generate(name: "Studio Mac")
        XCTAssertEqual(pairing.key.count, 32)
        let link = pairing.link
        XCTAssertTrue(link.hasPrefix("housecontrol://pair?"))
        XCTAssertEqual(SyncPairing(link: "  \(link)\n"), pairing)
    }

    func testPairingLinkRejectsGarbage() {
        XCTAssertNil(SyncPairing(link: "https://example.com/pair?v=1&id=a&key=b"))
        XCTAssertNil(SyncPairing(link: "housecontrol://pair?v=1&id=abc&key=c2hvcnQ"))
        XCTAssertNil(SyncPairing(link: "housecontrol://pair?v=2&id=abc&key=\(SyncPairing.base64URL(Data(count: 32)))"))
        XCTAssertNil(SyncPairing(link: "tuyaSmart--qrLogin?token=abc"))
    }

    func testStateMessageRoundTrip() {
        let plan = Data("{\"rooms\":[]}".utf8)
        let state = SyncState(macName: "Mac", revision: "abc", plan: plan, userCode: "u1", smartLifeConnected: true)
        let full = SyncState(message: state.message(includingPlan: true))
        XCTAssertEqual(full?.plan, plan)
        XCTAssertEqual(full?.revision, "abc")
        XCTAssertEqual(full?.userCode, "u1")
        XCTAssertEqual(full?.smartLifeConnected, true)
        XCTAssertNil(SyncState(message: state.message(includingPlan: false))?.plan)
        XCTAssertNil(SyncState(message: ["type": "hello"]))
    }

    /// A server and a client in one process, over the real TLS-PSK transport.
    private func makePair(clientKey: Data? = nil) -> (SyncServer, SyncClient) {
        let server = SyncServer(store: MemorySecretStore())
        let pairing = server.reset(name: "Test Mac")
        server.stop()
        server.start(advertise: false)
        var forPhone = pairing
        if let clientKey { forPhone.key = clientKey }
        let client = SyncClient(store: MemorySecretStore())
        client.deviceName = "Test iPhone"
        client.pair(forPhone)
        return (server, client)
    }

    private func waitForPort(_ server: SyncServer) async throws -> NWEndpoint {
        for _ in 0..<100 {
            if let port = server.port, port != 0 { return .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("The listener did not start (no network access in this environment?)")
    }

    func testPlanTravelsFromMacToPhoneAndUpdatesArePushed() async throws {
        let (server, client) = makePair()
        defer { client.stop(); server.stop() }
        var plan = Data("{\"name\":\"One\",\"rooms\":[]}".utf8)
        server.snapshot = {
            SyncState(macName: "Test Mac", revision: PlanStore.revision(of: plan), plan: plan, userCode: "code-1", smartLifeConnected: true)
        }
        var held: Data?
        client.planRevision = { held.map(PlanStore.revision(of:)) }

        let first = expectation(description: "first state")
        var received: [SyncState] = []
        client.onState = { state in
            received.append(state)
            if let data = state.plan { held = data }
            if received.count == 1 { first.fulfill() }
        }
        let peerSeen = expectation(description: "server saw the phone")
        server.onPeersChanged = { if server.connectedDevices == ["Test iPhone"] { peerSeen.fulfill() } }

        client.fixedEndpoint = try await waitForPort(server)
        client.start()
        await fulfillment(of: [first, peerSeen], timeout: 10)
        XCTAssertEqual(client.status, .connected)
        XCTAssertEqual(received[0].plan, plan)
        XCTAssertEqual(received[0].userCode, "code-1")

        // Asking again with the same revision must not resend the plan.
        let second = expectation(description: "refresh")
        client.onState = { state in received.append(state); second.fulfill() }
        client.refresh()
        await fulfillment(of: [second], timeout: 10)
        XCTAssertNil(received[1].plan)
        XCTAssertEqual(received[1].revision, PlanStore.revision(of: plan))

        // Saving a new plan on the Mac reaches the phone without it asking.
        let third = expectation(description: "push")
        client.onState = { state in received.append(state); third.fulfill() }
        plan = Data("{\"name\":\"Two\",\"rooms\":[]}".utf8)
        server.broadcast()
        await fulfillment(of: [third], timeout: 10)
        XCTAssertEqual(received[2].plan, plan)
    }

    func testPhoneCanPutAQRCodeOnTheMac() async throws {
        let (server, client) = makePair()
        defer { client.stop(); server.stop() }
        server.snapshot = { SyncState(macName: "Test Mac", revision: "", plan: nil, userCode: "", smartLifeConnected: false) }
        let connected = expectation(description: "connected")
        client.onState = { _ in connected.fulfill() }
        client.fixedEndpoint = try await waitForPort(server)
        client.start()
        await fulfillment(of: [connected], timeout: 10)

        let shown = expectation(description: "shown")
        let hiddenWhileAway = expectation(description: "hidden while the phone was away")
        hiddenWhileAway.isInverted = true
        let hidden = expectation(description: "hidden")
        let away = Flag()
        server.onShowQR = { content, device in
            XCTAssertEqual(device, "Test iPhone")
            if content == "tuyaSmart--qrLogin?token=t1" { shown.fulfill() }
            else if content == nil { (away.isSet ? hiddenWhileAway : hidden).fulfill() }
        }
        XCTAssertTrue(client.showQR("tuyaSmart--qrLogin?token=t1"))
        await fulfillment(of: [shown], timeout: 10)

        // The code is scanned from another app: ours goes to the background and iOS cuts
        // the connection. The code must stay up on the Mac.
        let gone = expectation(description: "phone disconnected")
        server.onPeersChanged = { if server.connectedDevices.isEmpty { gone.fulfill() } }
        away.isSet = true
        client.stop()
        await fulfillment(of: [gone], timeout: 10)
        server.onPeersChanged = nil
        await fulfillment(of: [hiddenWhileAway], timeout: 0.4)

        // Signed in while away: the Mac is told to take the code down once the phone is back.
        XCTAssertFalse(client.showQR(nil))
        away.isSet = false
        let back = expectation(description: "reconnected")
        client.onState = { _ in back.fulfill() }
        client.start()
        await fulfillment(of: [back, hidden], timeout: 10)
    }

    func testConnectionsGoToThePhoneAndAppleHomeComesBack() async throws {
        let (server, client) = makePair()
        defer { client.stop(); server.stop() }
        let shared: [String: Any] = ["homeassistant": ["url": "http://ha.local:8123", "token": "t"],
                                     "hue": ["host": "10.0.0.2", "key": "k"]]
        server.snapshot = { SyncState(macName: "Test Mac", revision: "", plan: nil, userCode: "", smartLifeConnected: false,
                                      connections: shared) }
        // Catalogs sent before the Mac is reachable are delivered once it is.
        client.sendCatalog([["id": "A1", "name": "Hall lamp", "kind": "light"]])
        let state = expectation(description: "state")
        var connections: [String: Any]?
        client.onState = { connections = $0.connections; state.fulfill() }
        let catalog = expectation(description: "catalog")
        server.onCatalog = { devices, phone in
            XCTAssertEqual(phone, "Test iPhone")
            XCTAssertEqual(devices.first?["name"] as? String, "Hall lamp")
            catalog.fulfill()
        }
        client.fixedEndpoint = try await waitForPort(server)
        client.start()
        await fulfillment(of: [state, catalog], timeout: 10)
        XCTAssertEqual((connections?["homeassistant"] as? [String: Any])?["token"] as? String, "t")
        XCTAssertEqual((connections?["hue"] as? [String: Any])?["key"] as? String, "k")
        // A Mac that predates connections sends none: the phone must keep its own.
        XCTAssertNil(SyncState(message: ["type": "state", "mac": "Old Mac"])?.connections)
    }

    func testPhoneSendsItsPlanAndConnectionsToTheMac() async throws {
        let (server, client) = makePair()
        defer { client.stop(); server.stop() }
        var macPlan: Data?
        server.snapshot = {
            SyncState(macName: "Test Mac", revision: macPlan.map(PlanStore.revision(of:)) ?? "", plan: macPlan,
                      userCode: "", smartLifeConnected: false)
        }
        let phonePlan = Data("{\"name\":\"Phone home\",\"rooms\":[{\"id\":\"a\",\"rect\":[0,0,3,3]}]}".utf8)
        client.planRevision = { PlanStore.revision(of: phonePlan) }
        let connected = expectation(description: "connected")
        client.onState = { _ in connected.fulfill() }
        client.fixedEndpoint = try await waitForPort(server)
        client.start()
        await fulfillment(of: [connected], timeout: 10)

        // The plan arrives byte for byte; the Mac's broadcast does not send it back.
        let arrived = expectation(description: "plan on the Mac")
        server.onPlan = { data, phone in
            XCTAssertEqual(phone, "Test iPhone")
            macPlan = data
            arrived.fulfill()
            server.broadcast()
        }
        let echoed = expectation(description: "state after the push")
        var after: SyncState?
        client.onState = { after = $0; echoed.fulfill() }
        XCTAssertTrue(client.sendPlan(phonePlan))
        await fulfillment(of: [arrived, echoed], timeout: 10)
        XCTAssertEqual(macPlan, phonePlan)
        XCTAssertEqual(after?.revision, PlanStore.revision(of: phonePlan))
        XCTAssertNil(after?.plan)

        // Something that is not a plan is dropped.
        server.onPlan = { _, _ in XCTFail("not a plan") }
        let shared = expectation(description: "connections on the Mac")
        server.onConnections = { connections, userCode, _ in
            XCTAssertEqual((connections["hue"] as? [String: Any])?["key"] as? String, "k")
            XCTAssertEqual(userCode, "u9")
            shared.fulfill()
        }
        client.sendPlan(Data("{\"name\":\"x\"}".utf8))
        client.sendConnections(["hue": ["host": "10.0.0.2", "key": "k", "updated": 5]], userCode: "u9")
        await fulfillment(of: [shared], timeout: 10)
    }

    func testConnectionsMergeByWhoChangedLast() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hc-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hub = DeviceHub(directory: folder)
        defer { hub.disconnect(service: "hue"); hub.disconnect(service: "homeassistant") }

        // Nothing set here yet: a peer's connection is taken, stamps and all.
        XCTAssertTrue(hub.adoptConnections(["hue": ["host": "10.0.0.2", "key": "k1", "updated": 100.0]]))
        XCTAssertEqual(hub.hue.info["host"] as? String, "10.0.0.2")
        XCTAssertEqual((hub.shareableConnections["hue"] as? [String: Any])?["updated"] as? Double, 100)
        // An older one is ignored, a newer one replaces it.
        XCTAssertFalse(hub.adoptConnections(["hue": ["host": "10.0.0.3", "key": "k0", "updated": 50.0]]))
        XCTAssertTrue(hub.adoptConnections(["hue": ["host": "10.0.0.4", "key": "k2", "updated": 200.0]]))
        XCTAssertEqual(hub.hue.info["host"] as? String, "10.0.0.4")
        // A platform the peer does not mention is left alone.
        XCTAssertFalse(hub.adoptConnections([:]))
        XCTAssertTrue(hub.hue.isConnected)
        // A newer disconnect travels as "removed".
        XCTAssertTrue(hub.adoptConnections(["hue": ["removed": true, "updated": 300.0]]))
        XCTAssertFalse(hub.hue.isConnected)
        // Disconnecting here is newer than anything the peer had, and is shared.
        XCTAssertTrue(hub.adoptConnections(["homeassistant": ["url": "http://ha.local:8123", "token": "t", "updated": 10.0]]))
        hub.disconnect(service: "homeassistant")
        XCTAssertEqual((hub.shareableConnections["homeassistant"] as? [String: Any])?["removed"] as? Bool, true)
        XCTAssertFalse(hub.adoptConnections(["homeassistant": ["url": "http://ha.local:8123", "token": "t", "updated": 10.0]]))
        XCTAssertFalse(hub.homeAssistant.isConnected)
    }

    func testAWrongKeyIsRefused() async throws {
        let (server, client) = makePair(clientKey: Data(repeating: 7, count: 32))
        defer { client.stop(); server.stop() }
        var served = false
        server.snapshot = { served = true; return SyncState(macName: "Test Mac", revision: "", plan: nil, userCode: "", smartLifeConnected: false) }
        let refused = expectation(description: "refused")
        refused.assertForOverFulfill = false
        client.onStatus = { if case .failed = client.status { refused.fulfill() } }
        client.onState = { _ in XCTFail("a phone with the wrong key must not receive anything") }
        client.fixedEndpoint = try await waitForPort(server)
        client.start()
        await fulfillment(of: [refused], timeout: 10)
        XCTAssertFalse(served)
        XCTAssertTrue(server.connectedDevices.isEmpty)
    }

    func testRenamingTheMacKeepsTheKey() {
        let server = SyncServer(store: MemorySecretStore())
        let first = server.reset(name: "Old name")
        server.stop()
        let renamed = server.enable(name: "New name")
        server.stop()
        XCTAssertEqual(renamed.name, "New name")
        XCTAssertEqual(renamed.key, first.key)
        XCTAssertEqual(renamed.id, first.id)
    }

    func testPairingSurvivesARestart() {
        let store = MemorySecretStore()
        let pairing = SyncServer(store: store).reset(name: "Mac")
        let again = SyncServer(store: store)
        XCTAssertEqual(again.pairing, pairing)
        again.disable()
        XCTAssertNil(SyncServer(store: store).pairing)
    }
}
