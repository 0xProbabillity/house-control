import XCTest
@testable import HouseCore

final class HueNetworkingTests: XCTestCase {
    func testTrustHostNormalizationMatchesURLAndChallengeFormats() {
        let cases = [
            ("192.168.1.2", "192.168.1.2"),
            ("192.168.1.2:8443", "192.168.1.2"),
            ("BRIDGE.local.:443", "bridge.local"),
            ("[fe80::1%25en11]:443", "fe80::1"),
            ("[fe80::1%25en11]", "fe80::1"),
            ("fe80::1%en11", "fe80::1"),
            ("fe80::1", "fe80::1"), ("::1", "::1"),
            ("fe80:0:0:0:217:88ff:fe12:3456%en0", "fe80:0:0:0:217:88ff:fe12:3456"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(BridgeTrust.bare(input), expected, input)
            XCTAssertEqual(BridgeTrust.bare(BridgeTrust.bare(input)), expected, input)
        }
    }

    @MainActor
    func testBridgeHostnameRejectsMalformedIDs() {
        for id in ["001788FFFE123456", "00:17:88:FF:FE:12:34:56", "00-17-88-FF-FE-12-34-56"] {
            XCTAssertEqual(HueService.bonjourHostname(bridgeId: id), "001788123456.local")
        }
        for id: String? in [nil, "", "001788123456", "0017880000123456", "garbage001788FFFE123456!"] {
            XCTAssertNil(HueService.bonjourHostname(bridgeId: id))
        }
    }

    @MainActor
    func testMigrationKeepsCredentialsAndPreservesCustomEndpoints() throws {
        for (host, expected) in [
            ("[fe80::1%25en11]", "001788123456.local"),
            ("192.168.1.50", "192.168.1.50"),
            ("192.168.1.50:8443", "192.168.1.50:8443"),
            ("[fe80::1%25en11]:8443", "[fe80::1%25en11]:8443"),
        ] {
            let config = HueService.Config(host: host, key: "saved-key", bridgeId: "001788FFFE123456", certificate: "saved-pin")
            let vault = MemorySecretStore(try JSONEncoder().encode(config))
            let service = HueService(vault: vault)
            let saved = try JSONDecoder().decode(HueService.Config.self, from: XCTUnwrap(vault.read()))
            XCTAssertEqual(saved.host, expected)
            XCTAssertEqual(saved.key, config.key)
            XCTAssertEqual(saved.certificate, config.certificate)
            service.disconnect()
        }
    }

    func testTemporaryResolverSurvivesTimeout() async {
        let result = await BonjourServiceResolver().resolve(
            name: UUID().uuidString, type: "_hue._tcp", domain: "local.", interfaceIndex: 0
        )
        XCTAssertNil(result)
    }

    func testResolverCancellationCompletesPromptly() async {
        let task = Task {
            await BonjourServiceResolver().resolve(
                name: UUID().uuidString, type: "_hue._tcp", domain: "local.", interfaceIndex: 0
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }
    func testResolverCancellationAfterStarting() async throws {
        let task = Task {
            await BonjourServiceResolver().resolve(
                name: UUID().uuidString, type: "_hue._tcp", domain: "local.", interfaceIndex: 0
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

}
