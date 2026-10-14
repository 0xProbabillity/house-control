import XCTest
@testable import HouseCore

final class WidgetTests: XCTestCase {
    private func home() -> HomeSnapshot {
        let room = HomeSnapshot.Room(id: "living", name: "Living", x: 0, z: 0, w: 4, d: 3, floor: "oak")
        func lamp(_ id: String, caps: [String], on: Bool, color: String? = nil) -> HomeSnapshot.Light {
            .init(id: id, name: id, room: "living", type: "ceiling", x: 1, z: 1, capabilities: caps,
                  on: on, brightness: 0.8, temp: 3000, color: color, service: nil, links: nil)
        }
        let ac = HomeSnapshot.AC(id: "ac", name: "AC", room: "living", wall: "west", x: 0, z: 1, min: 16, max: 30,
                                 on: false, target: 24, mode: "cool", fan: "auto", roomTemp: 26.5,
                                 swing: "swing", sleep: false, eco: false, service: nil, links: nil)
        let cozy = HomeSnapshot.Scene(id: "cozy", name: "Cozy", icon: "sofa",
                                      lights: ["*": ["on": .bool(false)], "tv": ["on": .bool(true), "color": .string("#ff7a3c")],
                                               "main": ["on": .bool(true), "brightness": .number(0.3), "temp": .number(2400)]],
                                      acs: ["*": ["on": .bool(true), "target": .number(22)]])
        return HomeSnapshot(name: "Home", plan: "home", rooms: [room],
                            lights: [lamp("main", caps: ["brightness", "temp"], on: false),
                                     lamp("tv", caps: ["brightness", "color"], on: false),
                                     lamp("plug", caps: [], on: true, color: "#ffffff")],
                            acs: [ac], scenes: [cozy])
    }

    func testToggleIsResolved() {
        var h = home()
        let (resolved, changes) = h.apply(.light("main"))
        XCTAssertEqual(resolved.on, true)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].patch["on"] as? Bool, true)
        XCTAssertTrue(h.light("main")!.on)
    }

    func testRoomTurnsOffWhenAnyIsOn() {
        var h = home()
        let (resolved, changes) = h.apply(.room("living"))
        XCTAssertEqual(resolved.on, false)
        XCTAssertEqual(changes.map(\.id), ["plug"])
        XCTAssertEqual(h.lightsOn, 0)
    }

    func testSceneFollowsTheStoreRules() {
        var h = home()
        let (_, changes) = h.apply(.scene("cozy"))
        XCTAssertEqual(h.scene, "cozy")
        let main = h.light("main")!
        XCTAssertTrue(main.on)
        XCTAssertEqual(main.brightness, 0.3)
        XCTAssertEqual(main.temp, 2400)
        XCTAssertEqual(h.light("tv")!.color, "#ff7a3c")
        XCTAssertFalse(h.light("plug")!.on)
        // A plug cannot take a colour: the scene's temperature rule leaves it alone.
        XCTAssertEqual(h.light("plug")!.color, "#ffffff")
        let ac = h.ac("ac")!
        XCTAssertTrue(ac.on)
        XCTAssertEqual(ac.target, 22)
        XCTAssertEqual(Set(changes.map(\.id)), ["main", "tv", "plug", "ac"])
        // Changing a lamp by hand leaves the scene.
        _ = h.apply(.light("tv", on: false))
        XCTAssertNil(h.scene)
    }

    func testTargetIsClampedAndRounded() {
        var h = home()
        XCTAssertEqual(h.apply(.acTarget("ac", 40)).resolved.target, 30)
        XCTAssertEqual(h.apply(.acTarget("ac", 21.6)).resolved.target, 22)
        XCTAssertEqual(h.ac("ac")!.target, 22)
        XCTAssertTrue(h.apply(.acTarget("ac", 22)).changes.isEmpty)
    }

    func testSnapshotDecodesThePagesJSON() throws {
        let json = """
        {"version":1,"name":"Home","plan":"home","outdoorTemp":27,"updated":1,"scene":null,
         "rooms":[{"id":"r","name":"R","x":0,"z":0,"w":1,"d":1}],
         "lights":[{"id":"l","name":"L","room":"r","type":"floor","x":0.5,"z":0.5,"capabilities":[],"on":true,
                    "brightness":0.8,"temp":3000,"color":null,"service":"smartlife","links":{"tuya":{"deviceId":"abc"}}}],
         "acs":[],"scenes":[{"id":"s","name":"S","icon":"sun","lights":{"*":{"on":true}},"acs":{}}]}
        """
        let h = try JSONDecoder().decode(HomeSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(h.lights[0].service, "smartlife")
        XCTAssertFalse(h.isSimulated)
        let plan = h.linksPlan
        let lamp = (plan["lights"] as? [[String: Any]])?.first
        XCTAssertEqual((lamp?["tuya"] as? [String: Any])?["deviceId"] as? String, "abc")
    }

    func testQueueAndPublish() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = SharedHome(directory: dir)
        XCTAssertNil(shared.perform(.light("main")), "no snapshot yet")
        XCTAssertTrue(shared.publish(home()))
        XCTAssertFalse(shared.publish(home()), "unchanged")
        let done = try XCTUnwrap(shared.perform(.light("main")))
        XCTAssertEqual(done.entry.action.on, true)
        XCTAssertTrue(shared.snapshot()!.light("main")!.on)
        // The app's older view must not overwrite what the widget did.
        XCTAssertFalse(shared.publish(home()))
        XCTAssertFalse(shared.isTaken(done.entry.id))
        let taken = shared.takeActions()
        XCTAssertEqual(taken.actions.map(\.id), [done.entry.id])
        XCTAssertTrue(shared.isTaken(done.entry.id))
        XCTAssertTrue(shared.publish(home()))
    }

    /// The app starting up must show what a widget did, not overwrite it with its own older view.
    @MainActor
    func testBridgeAdoptsBeforePublishing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = SharedHome(directory: dir)
        shared.publish(home())
        let done = try XCTUnwrap(shared.perform(.light("main")))
        shared.markDelivered([done.entry.id])

        let bridge = WidgetBridge(shared: shared)
        var adopted: [String: Any]?
        var ran: [[String: Any]] = []
        bridge.onActions = { run, adopt in ran = run; adopted = adopt }
        bridge.isReady = true
        let stale = try JSONSerialization.jsonObject(with: JSONEncoder().encode(home()))
        bridge.publish(["snapshot": stale])
        XCTAssertTrue(ran.isEmpty, "delivered by the widget: not sent again")
        let lights = try XCTUnwrap(adopted?["lights"] as? [String: Any])
        XCTAssertEqual((lights["main"] as? [String: Any])?["on"] as? Bool, true)
        XCTAssertTrue(shared.snapshot()!.light("main")!.on, "the stale snapshot was not stored")
    }
}
