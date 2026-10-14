import XCTest
@testable import HouseCore

/// Which address a discovered device is kept at, and when a paired Hue Bridge may be moved to
/// a new one. No network: these are the decisions, not the lookups.
@MainActor
final class DiscoveryTests: XCTestCase {

    // MARK: - Address formatting

    func testURLHostBracketsIPv6AndDropsItsScope() {
        XCTAssertEqual(ServiceDiscovery.urlHost("192.168.1.20"), "192.168.1.20")
        XCTAssertEqual(ServiceDiscovery.urlHost("fe80::eeb5:faff:fe2b:8a20%en0"), "[fe80::eeb5:faff:fe2b:8a20]")
        XCTAssertEqual(ServiceDiscovery.urlHost("2001:db8::1"), "[2001:db8::1]")
        XCTAssertEqual(ServiceDiscovery.urlHost("bridge.local"), "bridge.local")
    }

    // MARK: - Link-local detection

    func testLinkLocalCoversFe80Slash10Only() {
        XCTAssertTrue(HueService.isLinkLocal("[fe80::eeb5:faff:fe2b:8a20]"))
        XCTAssertTrue(HueService.isLinkLocal("[FEBF::1]"))       // still inside fe80::/10
        XCTAssertTrue(HueService.isLinkLocal("[fe80::1]:443"))
        XCTAssertFalse(HueService.isLinkLocal("[fec0::1]"))      // just outside it
        XCTAssertFalse(HueService.isLinkLocal("[2001:db8::1]"))
        XCTAssertFalse(HueService.isLinkLocal("192.168.178.176"))
        XCTAssertFalse(HueService.isLinkLocal("localhost:8443"))
    }

    // MARK: - Relocating a paired bridge

    private func config(host: String = "[fe80::1]", bridgeId: String? = "ecb5fafffe2b8a20", certificate: String? = "ab12") -> HueService.Config {
        HueService.Config(host: host, key: "secret", bridgeId: bridgeId, name: "Hue Bridge", certificate: certificate)
    }

    func testMovesToTheSameBridgeFoundOverIPv4() {
        let found: [[String: Any]] = [
            ["host": "192.168.1.9", "bridgeId": "001788fffe000000"],  // another bridge
            ["host": "192.168.178.176", "bridgeId": "ECB5FAFFFE2B8A20"], // ours, in upper case
        ]
        XCTAssertEqual(HueService.relocatedHost(for: config(), among: found), "192.168.178.176")
    }

    func testDoesNotMoveWithoutAPinnedCertificate() {
        // Without a pin, a device that only claims the bridge id would be trusted on first use
        // and sent the key: an older pairing is left alone instead.
        let found: [[String: Any]] = [["host": "192.168.178.176", "bridgeId": "ecb5fafffe2b8a20"]]
        XCTAssertNil(HueService.relocatedHost(for: config(certificate: nil), among: found))
        XCTAssertNil(HueService.relocatedHost(for: config(bridgeId: nil), among: found))
    }

    func testIgnoresLinkLocalAndUnchangedAddresses() {
        XCTAssertNil(HueService.relocatedHost(for: config(), among: [["host": "[fe80::2]", "bridgeId": "ecb5fafffe2b8a20"]]))
        XCTAssertNil(HueService.relocatedHost(for: config(host: "192.168.178.176"), among: [["host": "192.168.178.176", "bridgeId": "ecb5fafffe2b8a20"]]))
        XCTAssertNil(HueService.relocatedHost(for: config(), among: []))
    }
}
