import XCTest
@testable import HouseCore

final class PlanEditorTests: XCTestCase {
    private func sample() -> [String: Any] {
        var plan = PlanEditor.blank(name: "Flat")
        plan["lights"] = [["id": "living.light", "name": "Ceiling", "room": "living", "type": "ceiling", "pos": [2.5, 2], "capabilities": []]]
        plan["acs"] = [["id": "living.ac", "name": "AC", "room": "living", "wall": "north", "pos": [2.5, 0],
                        "tuya": ["deviceId": "old", "sensorId": "s1"]]]
        return plan
    }

    func testItemsAndLinks() {
        let editor = PlanEditor(plan: sample())
        XCTAssertEqual(editor.rooms.map(\.name), ["Living room"])
        XCTAssertEqual(editor.items.map(\.id), ["living.light", "living.ac"])
        XCTAssertNil(editor.items[0].link)
        XCTAssertEqual(editor.items[1].link, .init(service: "smartlife", id: "old"))
        XCTAssertEqual(editor.items[1].sensor, .init(service: "smartlife", id: "s1"))
        XCTAssertEqual(editor.items[1].roomName, "Living room")
    }

    func testLinkingFollowsTheWebEditorsRules() {
        var editor = PlanEditor(plan: sample())
        editor.link("living.light", to: ["service": "hue", "id": "h1", "kind": "light", "capabilities": ["brightness", "temp"]])
        var light = (editor.plan["lights"] as! [[String: Any]])[0]
        XCTAssertEqual(light["link"] as? [String: String], ["service": "hue", "id": "h1"])
        XCTAssertEqual(light["capabilities"] as? [String], ["brightness", "temp"])

        editor.link("living.light", to: ["service": "smartlife", "id": "t1", "kind": "light"])
        light = (editor.plan["lights"] as! [[String: Any]])[0]
        XCTAssertNil(light["link"])
        XCTAssertEqual((light["tuya"] as? [String: Any])?["deviceId"] as? String, "t1")

        // An AC moved to Home Assistant loses its Smart Life thermometer and takes the range.
        editor.link("living.ac", to: ["service": "homeassistant", "id": "climate.x", "kind": "ac", "min": 17.0, "max": 31.0])
        var ac = (editor.plan["acs"] as! [[String: Any]])[0]
        XCTAssertNil(ac["tuya"])
        XCTAssertEqual(ac["min"] as? Int, 17)
        XCTAssertEqual(ac["max"] as? Int, 31)
        XCTAssertNil(ac["capabilities"])

        editor.setSensor("living.ac", to: ["service": "hue", "id": "temp1", "kind": "sensor"])
        ac = (editor.plan["acs"] as! [[String: Any]])[0]
        XCTAssertEqual(ac["sensor"] as? [String: String], ["service": "hue", "id": "temp1"])
        XCTAssertEqual(editor.usedDevices[.init(service: "hue", id: "temp1")], "AC · room")

        editor.link("living.ac", to: nil)
        editor.setSensor("living.ac", to: nil)
        ac = (editor.plan["acs"] as! [[String: Any]])[0]
        XCTAssertNil(ac["link"])
        XCTAssertNil(ac["sensor"])
        XCTAssertNil(editor.items[1].link)
    }

    func testAddingDevicesMakesAValidLinkedPlan() throws {
        var editor = PlanEditor(plan: sample())
        let added = editor.add([
            ["service": "smartlife", "id": "p1", "kind": "light", "name": "Desk lamp", "capabilities": []],
            ["service": "hue", "id": "h2", "kind": "light", "name": "LED strip", "capabilities": ["color"]],
            ["service": "homeassistant", "id": "climate.y", "kind": "ac", "name": "Bedroom AC", "min": 16.0, "max": 30.0],
            ["service": "hue", "id": "t", "kind": "sensor", "name": "Motion"],
        ], to: "living")
        XCTAssertEqual(added, ["living.light2", "living.light3", "living.ac2"])
        let lights = editor.plan["lights"] as! [[String: Any]]
        XCTAssertEqual(lights[1]["type"] as? String, "table")
        XCTAssertEqual(lights[2]["type"] as? String, "strip")
        XCTAssertEqual(lights[2]["capabilities"] as? [String], ["color"])
        XCTAssertEqual((lights[1]["tuya"] as? [String: Any])?["deviceId"] as? String, "p1")
        // Every new lamp stands inside the room, none on another.
        let spots = lights.map { ($0["pos"] as! [Double]) }
        XCTAssertEqual(Set(spots.map { "\($0)" }).count, spots.count)
        for p in spots { XCTAssertTrue((0...5).contains(p[0]) && (0...4).contains(p[1])) }
        let ac = (editor.plan["acs"] as! [[String: Any]])[1]
        XCTAssertEqual(ac["wall"] as? String, "south") // the north wall already has one
        XCTAssertEqual(ac["pos"] as? [Double], [2.5, 4])
        XCTAssertEqual(ac["link"] as? [String: String], ["service": "homeassistant", "id": "climate.y"])
        // Still a plan the stores accept.
        _ = try PlanStore.validate(PlanStore.encode(editor.plan))
    }

    func testRoomsAndRemoval() {
        var editor = PlanEditor(plan: sample())
        let id = editor.addRoom(named: "Спальня")
        XCTAssertEqual(id, "room")
        XCTAssertEqual(editor.addRoom(named: "Kids' room"), "kids-room")
        let rects = (editor.plan["rooms"] as! [[String: Any]]).map { ($0["rect"] as! [NSNumber]).map(\.doubleValue) }
        XCTAssertEqual(rects[1][0], 5) // east of the living room
        XCTAssertEqual(rects[2][0], 9)

        var plan = editor.plan
        plan["scenes"] = [["id": "s", "lights": ["living.light": ["on": true], "*": ["on": false]]]]
        editor = PlanEditor(plan: plan)
        editor.remove("living.light")
        XCTAssertEqual(editor.items.map(\.id), ["living.ac"])
        let rules = (editor.plan["scenes"] as! [[String: Any]])[0]["lights"] as! [String: Any]
        XCTAssertEqual(Array(rules.keys), ["*"])
    }

    func testFixtureGuess() {
        XCTAssertEqual(PlanEditor.fixture(for: "Bedside Lamp"), "table")
        XCTAssertEqual(PlanEditor.fixture(for: "Hue color lamp"), "ceiling")
        XCTAssertEqual(PlanEditor.fixture(for: "Торшер"), "floor")
        XCTAssertEqual(PlanEditor.fixture(for: "Kitchen"), "ceiling")
    }
}
