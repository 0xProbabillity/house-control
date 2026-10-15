import XCTest
@testable import HouseCore

/// Home Assistant, Philips Hue and Apple Home: their translation to and from the panel's
/// vocabulary, and the hub's routing. `HOUSE_TEST_HA_URL` + `HOUSE_TEST_HA_TOKEN` also run
/// the Home Assistant client against a real server (tools/lab/homeassistant.sh starts one).
@MainActor
final class ServiceTests: XCTestCase {

    // MARK: - Colour

    func testColourConversionsRoundTrip() {
        for hex in ["#ff0000", "#00ff00", "#0000ff", "#ffa040", "#8050ff"] {
            let (h, s, _) = ColorMath.hsv(hex)!
            XCTAssertEqual(ColorMath.hex(hue: h, saturation: s), hex)
            let (x, y) = ColorMath.xy(hex)!
            let back = ColorMath.rgb(ColorMath.hex(x: x, y: y))!, orig = ColorMath.rgb(hex)!
            XCTAssertEqual(back.r, orig.r, accuracy: 0.03, hex)
            XCTAssertEqual(back.g, orig.g, accuracy: 0.03, hex)
            XCTAssertEqual(back.b, orig.b, accuracy: 0.03, hex)
        }
        XCTAssertEqual(ColorMath.mired(kelvin: 2500), 400)
        XCTAssertEqual(ColorMath.kelvin(mired: 250), 4000)
        XCTAssertNil(ColorMath.rgb("red"))
    }

    // MARK: - Home Assistant

    func testHomeAssistantListsLightsClimateAndSensors() {
        let light = HomeAssistantService.device(from: [
            "entity_id": "light.bed_light", "state": "off",
            "attributes": ["friendly_name": "Bed Light", "supported_color_modes": ["color_temp", "hs"]],
        ])
        XCTAssertEqual(light?.kind, .light)
        XCTAssertEqual(light?.capabilities, ["brightness", "temp", "color"])
        let plug = HomeAssistantService.device(from: ["entity_id": "switch.decorative_lights", "state": "unavailable", "attributes": [:]])
        XCTAssertEqual(plug?.capabilities, [])
        XCTAssertEqual(plug?.online, false)
        let ac = HomeAssistantService.device(from: [
            "entity_id": "climate.hvac", "state": "cool", "attributes": ["min_temp": 7, "max_temp": 35, "hvac_modes": ["off", "cool"]],
        ])
        XCTAssertEqual(ac?.kind, .ac)
        XCTAssertEqual(ac?.range?.min, 10)
        XCTAssertEqual(ac?.range?.max, 32)
        XCTAssertEqual(HomeAssistantService.device(from: [
            "entity_id": "sensor.outside", "state": "15.6", "attributes": ["unit_of_measurement": "°C"],
        ])?.kind, .sensor)
        XCTAssertNil(HomeAssistantService.device(from: ["entity_id": "sensor.power", "state": "3", "attributes": ["unit_of_measurement": "W"]]))
        XCTAssertNil(HomeAssistantService.device(from: ["entity_id": "media_player.tv", "state": "on", "attributes": [:]]))
    }

    func testHomeAssistantReadsLightState() {
        let white = HomeAssistantService.reading(from: [
            "entity_id": "light.ceiling", "state": "on",
            "attributes": ["brightness": 255, "color_mode": "color_temp", "color_temp_kelvin": 2631],
        ]).light!
        XCTAssertEqual(white["on"] as? Bool, true)
        XCTAssertEqual(white["brightness"] as? Double, 1)
        XCTAssertEqual(white["temp"] as? Double, 2631)
        XCTAssertTrue(white["color"] is NSNull)
        let colour = HomeAssistantService.reading(from: [
            "entity_id": "light.kitchen", "state": "on",
            "attributes": ["brightness": 180, "color_mode": "hs", "rgb_color": [255, 64, 112]],
        ]).light!
        XCTAssertEqual(colour["color"] as? String, "#ff4070")
        XCTAssertEqual(HomeAssistantService.reading(from: ["entity_id": "light.x", "state": "unavailable", "attributes": [:]]).online, false)
    }

    func testHomeAssistantReadsClimate() {
        let reading = HomeAssistantService.reading(from: [
            "entity_id": "climate.hvac", "state": "fan_only",
            "attributes": ["hvac_modes": ["off", "heat", "cool", "auto", "dry", "fan_only"], "temperature": 21,
                           "current_temperature": 22, "fan_modes": ["on_low", "on_high", "auto_low", "auto_high", "off"],
                           "fan_mode": "on_high", "swing_modes": ["auto", "1", "off"], "swing_mode": "off",
                           "preset_modes": ["home", "eco"], "preset_mode": "eco"],
        ])
        XCTAssertEqual(reading.ac?["on"] as? Bool, true)
        XCTAssertEqual(reading.ac?["mode"] as? String, "fan")
        XCTAssertEqual(reading.ac?["target"] as? Double, 21)
        XCTAssertEqual(reading.ac?["roomTemp"] as? Double, 22)
        XCTAssertEqual(reading.ac?["fan"] as? String, "high")
        XCTAssertEqual(reading.ac?["swing"] as? String, "off")
        XCTAssertEqual(reading.ac?["eco"] as? Bool, true)
        XCTAssertEqual(reading.features?["modes"] as? [String], ["cool", "heat", "dry", "fan", "auto"])
        XCTAssertEqual(reading.features?["fans"] as? [String], ["low", "high"])
        XCTAssertEqual(reading.features?["eco"] as? Bool, true)
        XCTAssertEqual(reading.features?["sleep"] as? Bool, false)
        // A heat_cool-only thermostat reports a range instead of one set-point.
        let range = HomeAssistantService.reading(from: [
            "entity_id": "climate.ecobee", "state": "heat_cool",
            "attributes": ["hvac_modes": ["off", "heat_cool"], "target_temp_low": 21, "target_temp_high": 24],
        ])
        XCTAssertEqual(range.ac?["mode"] as? String, "auto")
        XCTAssertEqual(range.ac?["target"] as? Double, 23)
    }

    func testHomeAssistantBuildsServiceCalls() {
        let off = HomeAssistantService.calls(for: "light.a", patch: ["on": false], state: [:], fans: [:], modes: [:])
        XCTAssertEqual(off.map(\.service), ["turn_off"])
        let dim = HomeAssistantService.calls(for: "light.a", patch: ["brightness": 0.5, "temp": 3000.0], state: [:], fans: [:], modes: [:])
        XCTAssertEqual(dim.first?.service, "turn_on")
        XCTAssertEqual(dim.first?.data["brightness_pct"] as? Int, 50)
        XCTAssertEqual(dim.first?.data["color_temp_kelvin"] as? Int, 3000)
        XCTAssertEqual(dim.first?.data["entity_id"] as? String, "light.a")
        let colour = HomeAssistantService.calls(for: "light.a", patch: ["color": "#ff8000"], state: [:], fans: [:], modes: [:])
        XCTAssertEqual(colour.first?.data["rgb_color"] as? [Int], [255, 128, 0])
        XCTAssertEqual(HomeAssistantService.calls(for: "switch.p", patch: ["on": true], state: [:], fans: [:], modes: [:]).map(\.service), ["turn_on"])

        let modes = HomeAssistantService.modeTable(["off", "cool", "heat_cool", "fan_only"])
        XCTAssertEqual(modes, ["cool": "cool", "auto": "heat_cool", "fan": "fan_only"])
        let fans = FanNames.table(["on_low", "on_high", "auto_low", "off"])
        XCTAssertEqual(fans, ["low": "on_low", "high": "on_high"])
        let on = HomeAssistantService.calls(for: "climate.x", patch: ["on": true], state: ["mode": "auto"], fans: fans, modes: modes)
        XCTAssertEqual(on.first?.data["hvac_mode"] as? String, "heat_cool")
        let change = HomeAssistantService.calls(for: "climate.x", patch: ["target": 23.0, "fan": "high", "eco": true],
                                                state: ["mode": "cool"], fans: fans, modes: modes)
        XCTAssertEqual(Set(change.map(\.service)), ["set_temperature", "set_fan_mode", "set_preset_mode"])
        XCTAssertEqual(HomeAssistantService.calls(for: "climate.x", patch: ["on": false], state: [:], fans: fans, modes: modes)
            .first?.data["hvac_mode"] as? String, "off")
    }

    func testHomeAssistantAddressIsNormalized() throws {
        XCTAssertEqual(try HomeAssistantService.normalize("homeassistant.local"), "http://homeassistant.local:8123")
        XCTAssertEqual(try HomeAssistantService.normalize(" http://10.0.0.5:8123/ "), "http://10.0.0.5:8123")
        XCTAssertEqual(try HomeAssistantService.normalize("https://ha.example.com"), "https://ha.example.com")
        XCTAssertThrowsError(try HomeAssistantService.normalize(""))
    }

    // MARK: - Hue

    func testHueReadsAndWritesLights() {
        let white: [String: Any] = [
            "id": "l1", "metadata": ["name": "Desk", "archetype": "classic_bulb"], "on": ["on": true],
            "dimming": ["brightness": 50.0], "color_temperature": ["mirek": 400, "mirek_valid": true],
            "color": ["xy": ["x": 0.5, "y": 0.4]],
        ]
        let state = HueService.lightState(white)
        XCTAssertEqual(state["on"] as? Bool, true)
        XCTAssertEqual(state["brightness"] as? Double, 0.5)
        XCTAssertEqual(state["temp"] as? Double, 2500)
        let colour = HueService.lightState(["on": ["on": true], "color_temperature": ["mirek": NSNull(), "mirek_valid": false],
                                            "color": ["xy": ["x": 0.6915, "y": 0.3083]]])
        XCTAssertEqual(colour["color"] as? String, "#ff0000")
        XCTAssertEqual(HueService.device(fromLight: white)?.capabilities, ["brightness", "temp", "color"])
        XCTAssertEqual(HueService.device(fromLight: ["id": "p", "on": ["on": false]])?.capabilities, [])

        let body = HueService.lightBody(patch: ["on": true, "brightness": 0.42, "temp": 2500.0, "color": "#ff0000"])
        XCTAssertEqual((body["on"] as? [String: Bool])?["on"], true)
        XCTAssertEqual((body["dimming"] as? [String: Double])?["brightness"], 42)
        XCTAssertEqual((body["color_temperature"] as? [String: Int])?["mirek"], 400)
        XCTAssertEqual(((body["color"] as? [String: Any])?["xy"] as? [String: Double])?["x"] ?? 0, 0.64, accuracy: 0.01)
        XCTAssertEqual(HueService.roomIndex([["metadata": ["name": "Living"], "children": [["rid": "dev1", "rtype": "device"]]]]),
                       ["dev1": "Living"])
        XCTAssertEqual(HueService.temperature(["temperature": ["temperature_report": ["temperature": 21.5]]]), 21.5)
    }

    // MARK: - Apple Home

    func testHomeKitMapsLights() {
        XCTAssertEqual(HomeKitMapper.kind(ofService: "00000043-0000-1000-8000-0026bb765291"), .light)
        XCTAssertEqual(HomeKitMapper.name(ofCharacteristic: "000000CE-0000-1000-8000-0026BB765291"), "colorTemperature")
        XCTAssertEqual(HomeKitMapper.capabilities(["on", "brightness", "hue", "saturation"]), ["brightness", "color"])
        let white = HomeKitMapper.lightState(["on": true, "brightness": 40, "colorTemperature": 250, "hue": 30, "saturation": 5])
        XCTAssertEqual(white["temp"] as? Double, 4000)
        XCTAssertEqual(white["brightness"] as? Double, 0.4)
        let colour = HomeKitMapper.lightState(["on": 1, "hue": 120, "saturation": 100])
        XCTAssertEqual(colour["color"] as? String, "#00ff00")
        XCTAssertEqual(colour["on"] as? Bool, true)
        let writes = HomeKitMapper.lightWrites(["on": true, "brightness": 0.5, "temp": 6500.0, "color": "#0000ff"],
                                               kind: .light, has: ["on", "brightness", "colorTemperature", "hue", "saturation"],
                                               limits: ["colorTemperature": (153, 500)])
        XCTAssertEqual(writes.map(\.0), ["on", "brightness", "colorTemperature", "hue", "saturation"])
        XCTAssertEqual(writes[2].1 as? Int, 154)
        XCTAssertEqual(writes[3].1 as? Double, 240)
        XCTAssertEqual(HomeKitMapper.lightWrites(["on": false, "brightness": 0.3], kind: .outlet, has: ["on"]).map(\.0), ["on"])
    }

    func testHomeKitMapsAirConditioners() {
        let ac = HomeKitMapper.acState(["active": 1, "targetState": 1, "heatingThreshold": 22, "coolingThreshold": 25,
                                        "currentTemperature": 20.46, "rotationSpeed": 100, "swing": 0], kind: .heaterCooler)
        XCTAssertEqual(ac["on"] as? Bool, true)
        XCTAssertEqual(ac["mode"] as? String, "heat")
        XCTAssertEqual(ac["target"] as? Double, 22)
        XCTAssertEqual(ac["roomTemp"] as? Double, 20.5)
        XCTAssertEqual(ac["fan"] as? String, "high")
        XCTAssertEqual(ac["swing"] as? String, "off")
        let features = HomeKitMapper.acFeatures(kind: .heaterCooler, has: ["active", "rotationSpeed"], validModes: [1, 2])
        XCTAssertEqual(features["modes"] as? [String], ["cool", "heat"])
        XCTAssertEqual(features["fans"] as? [String], ["low", "medium", "high"])
        XCTAssertEqual(features["swing"] as? Bool, false)

        let cool = HomeKitMapper.acWrites(["mode": "cool", "target": 24.0], state: ["mode": "heat"], kind: .heaterCooler,
                                          has: ["active", "targetState", "coolingThreshold", "heatingThreshold"])
        XCTAssertEqual(cool.map(\.0), ["targetState", "coolingThreshold"])
        XCTAssertEqual(cool[0].1 as? Int, 2)
        let off = HomeKitMapper.acWrites(["on": false], state: [:], kind: .thermostat, has: ["targetHeatingCooling"])
        XCTAssertEqual(off.first?.1 as? Int, 0)
        let thermostat = HomeKitMapper.acState(["targetHeatingCooling": 3, "targetTemperature": 21.4], kind: .thermostat)
        XCTAssertEqual(thermostat["mode"] as? String, "auto")
        XCTAssertEqual(thermostat["target"] as? Double, 21)
    }

    // MARK: - Hub routing

    func testHubRoutesLinkedDevicesToTheirPlatform() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeService()
        let hub = DeviceHub(directory: dir, secret: { _ in MemorySecretStore() }, homeKit: fake)
        hub.setLinks(from: [
            "lights": [["id": "lamp", "link": ["service": "homekit", "id": "L1"]], ["id": "sim"]],
            "acs": [["id": "ac", "link": ["service": "homekit", "id": "A1"], "sensor": ["service": "homekit", "id": "S1"]],
                    ["id": "ac2", "sensor": ["service": "homekit", "id": "S1"]]],
        ])
        XCTAssertEqual(hub.linkedDeviceCount, 2)
        XCTAssertTrue(hub.canPoll)
        XCTAssertEqual(fake.watched, ["L1", "A1", "S1"])

        let sent = expectation(description: "sent")
        hub.command(["id": "lamp", "kind": "light", "patch": ["on": true], "state": ["on": true]]) { reply in
            XCTAssertEqual(reply["ok"] as? Bool, true)
            sent.fulfill()
        }
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(fake.sent.first?.id, "L1")
        XCTAssertEqual(fake.sent.first?.kind, .light)

        fake.failNext = true
        let refused = expectation(description: "refused")
        hub.command(["id": "ac", "kind": "ac", "patch": ["target": 22.0]]) { reply in
            XCTAssertEqual(reply["error"] as? String, "nope")
            refused.fulfill()
        }
        await fulfillment(of: [refused], timeout: 2)

        let update = await hub.poll()
        XCTAssertEqual((update?["lights"] as? [String: [String: Any]])?["lamp"]?["on"] as? Bool, true)
        let acs = update?["acs"] as? [String: [String: Any]]
        XCTAssertEqual(acs?["ac"]?["target"] as? Double, 23)
        XCTAssertEqual(acs?["ac"]?["roomTemp"] as? Double, 19.5)  // from the sensor, not the unit
        XCTAssertEqual(acs?["ac2"]?["roomTemp"] as? Double, 19.5) // a simulated AC with a real sensor
        XCTAssertNotNil((update?["features"] as? [String: Any])?["ac"])

        var simulated: [String: Any]?
        hub.command(["id": "sim", "kind": "light", "patch": ["on": true]]) { simulated = $0 }
        XCTAssertEqual(simulated?["ok"] as? Bool, true)
        XCTAssertTrue(fake.sent.count == 1)
    }

    // MARK: - A real Home Assistant (opt-in)

    func testLiveHomeAssistant() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HOUSE_TEST_HA_URL"], let token = env["HOUSE_TEST_HA_TOKEN"] else {
            throw XCTSkip("Set HOUSE_TEST_HA_URL and HOUSE_TEST_HA_TOKEN (tools/lab/homeassistant.sh prints them)")
        }
        let service = HomeAssistantService(vault: MemorySecretStore())
        do {
            try await service.connect(url: url, token: "wrong")
            XCTFail("a wrong token must be refused")
        } catch {}
        try await service.connect(url: url, token: token)
        XCTAssertTrue(service.isConnected)
        let devices = try await service.devices()
        let light = try XCTUnwrap(devices.first { $0.id == "light.bed_light" })
        XCTAssertEqual(light.capabilities, ["brightness", "temp", "color"])
        XCTAssertTrue(devices.contains { $0.kind == .ac })
        XCTAssertTrue(devices.contains { $0.kind == .sensor })

        try await service.send(kind: .light, id: "light.bed_light", patch: ["on": true, "brightness": 0.4, "temp": 3000.0], state: [:])
        var state = try await service.read(["light.bed_light"])["light.bed_light"]?.light
        XCTAssertEqual(state?["on"] as? Bool, true)
        XCTAssertEqual(state?["brightness"] as? Double ?? 0, 0.4, accuracy: 0.01)
        XCTAssertEqual(state?["temp"] as? Double ?? 0, 3000, accuracy: 30)
        try await service.send(kind: .light, id: "light.bed_light", patch: ["color": "#00ff00"], state: [:])
        state = try await service.read(["light.bed_light"])["light.bed_light"]?.light
        XCTAssertEqual(state?["color"] as? String, "#00ff00")
        try await service.send(kind: .light, id: "light.bed_light", patch: ["on": false], state: [:])
        state = try await service.read(["light.bed_light"])["light.bed_light"]?.light
        XCTAssertEqual(state?["on"] as? Bool, false)

        _ = try await service.read(["climate.hvac"]) // learns its mode and fan names
        try await service.send(kind: .ac, id: "climate.hvac", patch: ["mode": "heat", "target": 23.0, "fan": "high"], state: ["mode": "heat"])
        let ac = try await service.read(["climate.hvac"])["climate.hvac"]
        XCTAssertEqual(ac?.ac?["mode"] as? String, "heat")
        XCTAssertEqual(ac?.ac?["target"] as? Double, 23)
        XCTAssertEqual(ac?.ac?["fan"] as? String, "high")
        try await service.send(kind: .ac, id: "climate.hvac", patch: ["on": false], state: [:])
        let off = try await service.read(["climate.hvac"])["climate.hvac"]
        XCTAssertEqual(off?.ac?["on"] as? Bool, false)
        try await service.send(kind: .ac, id: "climate.hvac", patch: ["on": true], state: ["mode": "cool"])
        service.disconnect()
        XCTAssertFalse(service.isConnected)
    }

    // MARK: - A Hue Bridge (opt-in)

    /// `HOUSE_TEST_HUE_HOST=localhost:8443` with tools/lab/hue.mjs --auto running.
    func testLiveHueBridge() async throws {
        guard let host = ProcessInfo.processInfo.environment["HOUSE_TEST_HUE_HOST"] else {
            throw XCTSkip("Set HOUSE_TEST_HUE_HOST and run tools/lab/hue.mjs --auto")
        }
        let found = await ServiceDiscovery.hueBridges()
        XCTAssertTrue(found.contains { ($0["bridgeId"] as? String) == "ecb5fafffe0lab01" }, "announced over Bonjour: \(found)")

        let service = HueService(vault: MemorySecretStore())
        try await service.pair(host: host)
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.info["name"] as? String, "Hue Bridge Lab")
        let devices = try await service.devices()
        let lamp = try XCTUnwrap(devices.first { $0.name == "Hue color lamp" })
        XCTAssertEqual(lamp.capabilities, ["brightness", "temp", "color"])
        XCTAssertEqual(lamp.room, "Living room")
        XCTAssertEqual(devices.first { $0.name == "Hue smart plug" }?.capabilities, [])
        let sensor = try XCTUnwrap(devices.first { $0.kind == .sensor })

        let changed = expectation(description: "event stream")
        changed.assertForOverFulfill = false
        service.watch([lamp.id])
        service.onChange = { changed.fulfill() }
        try await Task.sleep(nanoseconds: 500_000_000) // let the stream connect
        try await service.send(kind: .light, id: lamp.id, patch: ["on": true, "brightness": 0.3, "color": "#0000ff"], state: [:])
        await fulfillment(of: [changed], timeout: 5)
        var readings = try await service.read([lamp.id, sensor.id])
        XCTAssertEqual(readings[lamp.id]?.light?["on"] as? Bool, true)
        XCTAssertEqual(readings[lamp.id]?.light?["brightness"] as? Double ?? 0, 0.3, accuracy: 0.001)
        let blue = ColorMath.rgb(readings[lamp.id]?.light?["color"] as? String ?? "")
        XCTAssertGreaterThan(blue?.b ?? 0, 0.9)
        XCTAssertNotNil(readings[sensor.id]?.temperature)
        try await service.send(kind: .light, id: lamp.id, patch: ["temp": 2700.0], state: [:])
        readings = try await service.read([lamp.id])
        XCTAssertEqual(readings[lamp.id]?.light?["temp"] as? Double ?? 0, 2700, accuracy: 20)

        // The key and the certificate travel to the iPhone together.
        let phone = HueService(vault: MemorySecretStore())
        phone.adopt(service.shareable)
        let onPhone = try await phone.devices()
        XCTAssertEqual(onPhone.count, devices.count)
        service.disconnect()
        phone.disconnect()
    }
}

/// A platform that answers from memory.
@MainActor
private final class FakeService: DeviceService {
    let id = "homekit"
    let title = "Fake"
    var onChange: (() -> Void)?
    var isConnected: Bool { true }
    var info: [String: Any] { ["connected": true] }
    var sent: [(kind: DeviceKind, id: String, patch: [String: Any])] = []
    var watched: Set<String> = []
    var failNext = false

    func devices() async throws -> [ServiceDevice] { [] }
    func read(_ ids: Set<String>) async throws -> [String: DeviceReading] {
        [
            "L1": DeviceReading(light: ["on": true, "brightness": 0.5]),
            "A1": DeviceReading(ac: ["on": true, "target": 23.0, "roomTemp": 26.0], features: ["modes": ["cool"]]),
            "S1": DeviceReading(temperature: 19.5),
        ].filter { ids.contains($0.key) }
    }
    func send(kind: DeviceKind, id: String, patch: [String: Any], state: [String: Any]) async throws {
        if failNext { failNext = false; throw ServiceFailure("nope") }
        sent.append((kind, id, patch))
    }
    func watch(_ ids: Set<String>) { watched = ids }
    func disconnect() {}
}
