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
