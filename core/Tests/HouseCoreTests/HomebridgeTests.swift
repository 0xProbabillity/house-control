import XCTest
@testable import HouseCore

/// Homebridge: the UI's accessory list in the panel's terms. `HOUSE_TEST_HOMEBRIDGE_URL`
/// (with tools/lab/homebridge.sh running) also runs the tests against a real Homebridge.
@MainActor
final class HomebridgeTests: XCTestCase {
    private func characteristic(_ short: String, _ type: String, _ value: Any, min: Double? = nil, max: Double? = nil,
                                valid: [Int]? = nil) -> [String: Any] {
        var c: [String: Any] = ["uuid": "000000\(short)-0000-1000-8000-0026BB765291", "type": type, "value": value]
        if let min { c["minValue"] = min }
        if let max { c["maxValue"] = max }
        if let valid { c["validValues"] = valid }
        return c
    }

    private var colourLamp: [String: Any] {
        ["uniqueId": "lamp1", "uuid": "00000043-0000-1000-8000-0026BB765291", "type": "Lightbulb", "humanType": "Lightbulb",
         "serviceName": "Strip", "accessoryInformation": ["Manufacturer": "Govee", "Name": "Strip"],
         "serviceCharacteristics": [
            characteristic("25", "On", 1), characteristic("08", "Brightness", 40, min: 0, max: 100),
            characteristic("CE", "ColorTemperature", 250, min: 140, max: 500),
            characteristic("13", "Hue", 120, min: 0, max: 360), characteristic("2F", "Saturation", 100, min: 0, max: 100),
         ]]
    }

    private var airConditioner: [String: Any] {
        ["uniqueId": "ac1", "uuid": "000000BC-0000-1000-8000-0026BB765291", "type": "HeaterCooler", "humanType": "Heater Cooler",
         "serviceName": "Bedroom AC", "accessoryInformation": ["Manufacturer": "Daikin"],
         "serviceCharacteristics": [
            characteristic("B0", "Active", 1), characteristic("B2", "TargetHeaterCoolerState", 2, valid: [1, 2]),
            characteristic("11", "CurrentTemperature", 25.4),
            characteristic("0D", "CoolingThresholdTemperature", 23, min: 18, max: 30),
            characteristic("12", "HeatingThresholdTemperature", 21, min: 16, max: 28),
            characteristic("29", "RotationSpeed", 100, min: 0, max: 100), characteristic("B6", "SwingMode", 1),
         ]]
    }

    func testListsLampsPlugsAndAirConditioners() throws {
        let lamp = try XCTUnwrap(HomebridgeService.device(from: colourLamp))
        XCTAssertEqual(lamp.kind, .light)
        XCTAssertEqual(lamp.capabilities, ["brightness", "temp", "color"])
        XCTAssertEqual(lamp.detail, "Govee · lightbulb")

        let plug: [String: Any] = ["uniqueId": "p", "uuid": "00000047-0000-1000-8000-0026BB765291", "type": "Outlet",
                                   "serviceName": "", "accessoryInformation": ["Name": "Kettle"],
                                   "serviceCharacteristics": [characteristic("25", "On", false)]]
        let outlet = try XCTUnwrap(HomebridgeService.device(from: plug))
        XCTAssertEqual(outlet.name, "Kettle")
        XCTAssertEqual(outlet.capabilities, [])

        let ac = try XCTUnwrap(HomebridgeService.device(from: airConditioner))
        XCTAssertEqual(ac.kind, .ac)
        XCTAssertEqual(ac.range?.min, 18)
        XCTAssertEqual(ac.range?.max, 30)

        // Services House Control has no use for are left out.
        let info: [String: Any] = ["uniqueId": "x", "uuid": "000000A2-0000-1000-8000-0026BB765291", "type": "ProtocolInformation"]
        XCTAssertNil(HomebridgeService.device(from: info))
    }

    func testReadsStateAndBuildsWrites() throws {
        let lamp = try XCTUnwrap(HomebridgeService.entry(from: colourLamp))
        let light = HomebridgeService.reading(lamp).light
        XCTAssertEqual(light?["on"] as? Bool, true)
        XCTAssertEqual(light?["brightness"] as? Double ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(light?["color"] as? String, "#00ff00")
        XCTAssertEqual(lamp.types["colorTemperature"], "ColorTemperature")
        // A white temperature out of the lamp's range is clamped to it.
        let writes = HomeKitMapper.lightWrites(["temp": 1500.0], kind: lamp.kind, has: Set(lamp.types.keys), limits: lamp.limits)
        XCTAssertEqual(writes.first?.0, "colorTemperature")
        XCTAssertEqual(writes.first?.1 as? Int, 500)

        let ac = try XCTUnwrap(HomebridgeService.entry(from: airConditioner))
        let reading = HomebridgeService.reading(ac)
        XCTAssertEqual(reading.ac?["on"] as? Bool, true)
        XCTAssertEqual(reading.ac?["mode"] as? String, "cool")
        XCTAssertEqual(reading.ac?["target"] as? Double, 23)
        XCTAssertEqual(reading.ac?["fan"] as? String, "high")
        XCTAssertEqual(reading.ac?["roomTemp"] as? Double, 25.4)
        // It only takes heat and cool.
        XCTAssertEqual(reading.features?["modes"] as? [String], ["cool", "heat"])
    }

    func testAddressIsNormalized() throws {
        XCTAssertEqual(try HomebridgeService.normalize("homebridge.local"), "http://homebridge.local:8581")
        XCTAssertEqual(try HomebridgeService.normalize(" http://10.0.0.5:8080/ "), "http://10.0.0.5:8080")
        XCTAssertEqual(try HomebridgeService.normalize("https://hb.example.lan"), "https://hb.example.lan")
        XCTAssertThrowsError(try HomebridgeService.normalize(""))
    }

    func testHubSharesTheConnection() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = DeviceHub(directory: directory, secret: { _ in MemorySecretStore() })
        XCTAssertTrue(hub.services.contains { $0.id == "homebridge" })
        XCTAssertTrue(hub.adoptConnections(["homebridge": ["url": "http://127.0.0.1:1", "username": "u", "password": "p",
                                                           "token": "t", "updated": 100.0]]))
        XCTAssertTrue(hub.homebridge.isConnected)
        XCTAssertEqual((hub.shareableConnections["homebridge"] as? [String: Any])?["password"] as? String, "p")
        XCTAssertTrue(hub.adoptConnections(["homebridge": ["removed": true, "updated": 200.0]]))
        XCTAssertFalse(hub.homebridge.isConnected)
    }

    // MARK: - A real Homebridge (opt-in)

    /// `HOUSE_TEST_HOMEBRIDGE_NO_CONTROL=http://127.0.0.1:8581` with `HB_INSECURE=0 tools/lab/homebridge.sh`.
    func testLiveHomebridgeWithoutAccessoryControl() async throws {
        guard let url = ProcessInfo.processInfo.environment["HOUSE_TEST_HOMEBRIDGE_NO_CONTROL"] else {
            throw XCTSkip("Set HOUSE_TEST_HOMEBRIDGE_NO_CONTROL and run HB_INSECURE=0 tools/lab/homebridge.sh")
        }
        let service = HomebridgeService(vault: MemorySecretStore())
        do {
            try await service.connect(url: url, username: "lab", password: "lab-lab-lab", code: nil)
            XCTFail("connecting without accessory control says how to turn it on")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Enable UI Accessory Control"), error.localizedDescription)
        }
        XCTAssertFalse(service.isConnected)
    }

    /// `HOUSE_TEST_HOMEBRIDGE_URL=http://127.0.0.1:8581` with tools/lab/homebridge.sh running.
    func testLiveHomebridge() async throws {
        guard let url = ProcessInfo.processInfo.environment["HOUSE_TEST_HOMEBRIDGE_URL"] else {
            throw XCTSkip("Set HOUSE_TEST_HOMEBRIDGE_URL and run tools/lab/homebridge.sh")
        }
        let found = await ServiceDiscovery.homebridges()
        XCTAssertTrue(found.contains { ($0["name"] as? String) == "Homebridge Lab" }, "found on the network: \(found)")

        let service = HomebridgeService(vault: MemorySecretStore())
        do {
            try await service.connect(url: url, username: "lab", password: "wrong", code: nil)
            XCTFail("a wrong password is refused")
        } catch is HomebridgeService.WrongCredentials {}
        try await service.connect(url: url, username: "lab", password: "lab-lab-lab", code: nil)
        XCTAssertEqual(service.info["name"] as? String, "Homebridge Lab")

        let devices = try await service.devices()
        let lamp = try XCTUnwrap(devices.first { $0.name == "Lab Colour Strip" })
        XCTAssertEqual(lamp.capabilities, ["brightness", "temp", "color"])
        XCTAssertEqual(devices.first { $0.name == "Lab Plug" }?.capabilities, [])
        let ac = try XCTUnwrap(devices.first { $0.name == "Lab AC" })
        let sensor = try XCTUnwrap(devices.first { $0.kind == .sensor })

        let changed = expectation(description: "socket.io update")
        changed.assertForOverFulfill = false
        service.watch([lamp.id])
        try await Task.sleep(nanoseconds: 6_000_000_000) // joined, past the first full lists
        service.onChange = { changed.fulfill() }
        try await service.send(kind: .light, id: lamp.id, patch: ["on": true, "brightness": 0.3, "color": "#0000ff"], state: [:])
        await fulfillment(of: [changed], timeout: 6)
        var readings = try await service.read([lamp.id, sensor.id, ac.id])
        XCTAssertEqual(readings[lamp.id]?.light?["on"] as? Bool, true)
        XCTAssertEqual(readings[lamp.id]?.light?["brightness"] as? Double ?? 0, 0.3, accuracy: 0.001)
        XCTAssertGreaterThan(ColorMath.rgb(readings[lamp.id]?.light?["color"] as? String ?? "")?.b ?? 0, 0.9)
        XCTAssertNotNil(readings[sensor.id]?.temperature)

        try await service.send(kind: .ac, id: ac.id, patch: ["on": true, "mode": "heat", "target": 25.0, "fan": "low"], state: ["mode": "cool"])
        readings = try await service.read([ac.id])
        XCTAssertEqual(readings[ac.id]?.ac?["on"] as? Bool, true)
        XCTAssertEqual(readings[ac.id]?.ac?["mode"] as? String, "heat")
        XCTAssertEqual(readings[ac.id]?.ac?["target"] as? Double, 25)
        XCTAssertEqual(readings[ac.id]?.ac?["fan"] as? String, "low")
        try await service.send(kind: .ac, id: ac.id, patch: ["on": false], state: [:])

        // An expired session is renewed with the kept sign-in.
        var shared = try XCTUnwrap(service.shareable)
        shared["token"] = "expired"
        let phone = HomebridgeService(vault: MemorySecretStore())
        phone.adopt(shared)
        let onPhone = try await phone.devices()
        XCTAssertEqual(onPhone.count, devices.count)
        XCTAssertNotEqual(phone.shareable?["token"] as? String, "expired")
        service.disconnect()
        phone.disconnect()
    }
}
