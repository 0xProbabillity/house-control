import XCTest
@testable import HouseCore

/// A scan made up the way RoomPlan reports one: three rooms drawn square, then turned 17° and
/// moved, as the AR session's world rarely lines up with the walls, the floor 1.3 m under
/// the session's origin, and a wall's thickness between rooms scanned one after the other.
enum SampleScan {
    static let angle = 17.0 * .pi / 180
    static let origin = (x: 3.0, z: -1.5)
    static let floor = -1.3

    static func point(_ x: Double, _ y: Double, _ z: Double) -> RoomScan.Point {
        RoomScan.Point(x: origin.x + x * cos(angle) - z * sin(angle), y: floor + y,
                       z: origin.z + x * sin(angle) + z * cos(angle))
    }

    static func axis(_ dx: Double, _ dz: Double) -> (Double, Double) {
        (dx * cos(angle) - dz * sin(angle), dx * sin(angle) + dz * cos(angle))
    }

    static func surface(_ kind: RoomScan.SurfaceKind, _ a: (Double, Double), _ b: (Double, Double),
                        bottom: Double = 0, height: Double = 2.7) -> RoomScan.Surface {
        let length = ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot()
        let (ax, az) = axis((b.0 - a.0) / length, (b.1 - a.1) / length)
        return RoomScan.Surface(kind: kind, center: point((a.0 + b.0) / 2, bottom + height / 2, (a.1 + b.1) / 2),
                                axisX: ax, axisZ: az, width: length, height: height)
    }

    static func walls(_ corners: [(Double, Double)]) -> [RoomScan.Surface] {
        corners.indices.map { surface(.wall, corners[$0], corners[($0 + 1) % corners.count]) }
    }

    /// `along` is the direction of its width in the square drawing.
    static func object(_ category: String, kind: String? = nil, at x: Double, _ z: Double, along: (Double, Double) = (1, 0),
                       width: Double, height: Double, depth: Double) -> RoomScan.Object {
        let (ax, az) = axis(along.0, along.1)
        return RoomScan.Object(category: category, kind: kind, center: point(x, height / 2, z), axisX: ax, axisZ: az,
                               width: width, height: height, depth: depth)
    }

    static var scan: RoomScan {
        let living = RoomScan.Room(
            walls: walls([(0, 0), (5, 0), (5, 4), (0, 4)]),
            openings: [
                surface(.door, (5, 1), (5, 1.9), height: 2.05),
                surface(.window, (1, 0), (2.5, 0), bottom: 0.9, height: 1.2),
            ],
            objects: [
                object("sofa", at: 2.5, 3.5, width: 2.2, height: 0.85, depth: 0.9),
                object("television", at: 2.5, 0.25, along: (-1, 0), width: 1.4, height: 0.7, depth: 0.1),
                object("table", kind: "coffee", at: 2.5, 2, width: 1.1, height: 0.45, depth: 0.6),
            ])
        let bedroom = RoomScan.Room(
            walls: walls([(5.15, 0), (8.5, 0), (8.5, 3.2), (5.15, 3.2)]),
            openings: [surface(.door, (5.15, 1.05), (5.15, 1.95), height: 2.05)],
            objects: [object("bed", at: 7.45, 1.6, along: (0, 1), width: 1.6, height: 0.5, depth: 2.1)],
            sections: [RoomScan.Section(label: "bedroom", center: point(6.8, 0, 1.6))])
        let kitchen = RoomScan.Room(
            walls: walls([(0, 4.12), (5, 4.12), (5, 5.5), (3, 5.5), (3, 7), (0, 7)]),
            objects: [
                object("stove", at: 1, 6.7, width: 0.6, height: 0.9, depth: 0.6),
                object("sink", at: 1.7, 6.7, width: 0.8, height: 0.9, depth: 0.6),
                object("refrigerator", at: 0.35, 5, along: (0, 1), width: 0.7, height: 1.8, depth: 0.7),
            ],
            sections: [RoomScan.Section(label: "kitchen", center: point(1.5, 0, 5.5))])
        return RoomScan(rooms: [living, bedroom, kitchen], tags: [
            RoomScan.Tag(id: "t1", kind: "light", name: "Ceiling", position: point(2.5, 2.68, 2),
                         device: RoomScan.Device(service: "hue", id: "h1", name: "Ceiling", capabilities: ["brightness", "color"])),
            RoomScan.Tag(id: "t2", kind: "light", name: "Lamp", position: point(0.4, 1.4, 3.6)),
            RoomScan.Tag(id: "t3", kind: "ac", name: "Bedroom AC", position: point(8.4, 2.2, 1.5),
                         device: RoomScan.Device(service: "smartlife", id: "ac1", name: "AC", min: 16, max: 31)),
        ])
    }
}

final class RoomScanTests: XCTestCase {
    private func build() throws -> [String: Any] {
        try XCTUnwrap(ScanLayout.plan(from: SampleScan.scan, name: "Flat"))
    }

    private func rooms(_ plan: [String: Any]) -> [String: [Double]] {
        Dictionary(uniqueKeysWithValues: (plan["rooms"] as! [[String: Any]]).map { ($0["name"] as! String, $0["rect"] as! [Double]) })
    }

    func testRoomsComeOutSquareSharingTheirWalls() throws {
        let plan = try build()
        XCTAssertEqual(plan["wallHeight"] as? Double, 2.7)
        let rooms = rooms(plan)
        XCTAssertEqual(Set(rooms.keys), ["Living room", "Bedroom", "Kitchen", "Kitchen 2"])
        // Rooms scanned apart meet in the middle of the wall between them.
        XCTAssertEqual(rooms["Living room"], [0, 0, 5.05, 4.08])
        XCTAssertEqual(rooms["Bedroom"], [5.05, 0, 3.45, 3.2])
        // The L-shaped kitchen is two rectangles, open to each other.
        XCTAssertEqual(rooms["Kitchen"], [0, 4.08, 3, 2.92])
        XCTAssertEqual(rooms["Kitchen 2"], [3, 4.08, 2.05, 1.42])
        let floors = Dictionary(uniqueKeysWithValues: (plan["rooms"] as! [[String: Any]]).map { ($0["name"] as! String, $0["floor"] as! String) })
        XCTAssertEqual(floors["Kitchen"], "stone")
        XCTAssertEqual(floors["Bedroom"], "walnut")
    }

    func testOpeningsSitOnTheRoomEdges() throws {
        let openings = try build()["openings"] as! [[String: Any]]
        let doors = openings.filter { $0["type"] as? String == "door" }
        XCTAssertEqual(doors.count, 1, "the door seen from both rooms is one door")
        XCTAssertEqual(doors[0]["from"] as? [Double], [5.05, 1])
        XCTAssertEqual(doors[0]["to"] as? [Double], [5.05, 1.95])
        let window = try XCTUnwrap(openings.first { $0["type"] as? String == "window" })
        XCTAssertEqual(window["from"] as? [Double], [1, 0])
        XCTAssertEqual(window["to"] as? [Double], [2.5, 0])
        XCTAssertEqual(window["sill"] as? Double, 0.9)
        XCTAssertEqual(window["head"] as? Double, 2.1)
        let open = openings.filter { $0["type"] as? String == "open" }
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0]["from"] as? [Double], [3, 4.08])
        XCTAssertEqual(open[0]["to"] as? [Double], [3, 5.5])
    }

    func testFurnitureStandsWithItsBackToTheWall() throws {
        let furniture = try build()["furniture"] as! [[String: Any]]
        func piece(_ type: String) throws -> [String: Any] { try XCTUnwrap(furniture.first { $0["type"] as? String == type }, type) }
        XCTAssertEqual(try piece("sofa")["rot"] as? Double, 180)
        XCTAssertEqual(try piece("sofa")["width"] as? Double, 2.2)
        XCTAssertNil(try piece("tv")["rot"])
        XCTAssertEqual(try piece("coffeeTable")["pos"] as? [Double], [2.5, 2])
        XCTAssertEqual(try piece("bed")["rot"] as? Double, -90)
        XCTAssertEqual(try piece("bed")["width"] as? Double, 1.6)
        XCTAssertEqual(try piece("fridge")["rot"] as? Double, 90)
        // The stove and the sink are one run of kitchen along the south wall.
        let kitchens = furniture.filter { $0["type"] as? String == "kitchen" }
        XCTAssertEqual(kitchens.count, 1)
        XCTAssertEqual(kitchens[0]["width"] as? Double, 1.4)
        XCTAssertEqual(kitchens[0]["rot"] as? Double, 180)
        XCTAssertEqual(kitchens[0]["pos"] as? [Double], [1.4, 6.7])
    }

    func testTaggedDevicesLandInTheirRoomsLinked() throws {
        let plan = try build()
        let lights = plan["lights"] as! [[String: Any]]
        XCTAssertEqual(lights.count, 2)
        XCTAssertEqual(lights[0]["room"] as? String, "living-room")
        XCTAssertEqual(lights[0]["type"] as? String, "ceiling")
        XCTAssertEqual(lights[0]["link"] as? [String: String], ["service": "hue", "id": "h1"])
        XCTAssertEqual(lights[0]["capabilities"] as? [String], ["brightness", "color"])
        XCTAssertEqual(lights[1]["type"] as? String, "floor")
        XCTAssertNil(lights[1]["link"])
        XCTAssertEqual(lights[1]["pos"] as? [Double], [0.4, 3.6])

        let acs = plan["acs"] as! [[String: Any]]
        XCTAssertEqual(acs.count, 1)
        XCTAssertEqual(acs[0]["room"] as? String, "bedroom")
        XCTAssertEqual(acs[0]["wall"] as? String, "east")
        XCTAssertEqual(acs[0]["pos"] as? [Double], [8.5, 1.5])
        XCTAssertEqual(acs[0]["y"] as? Double, 2.2)
        XCTAssertEqual((acs[0]["tuya"] as? [String: Any])?["deviceId"] as? String, "ac1")
        XCTAssertEqual(acs[0]["max"] as? Int, 31)

        let editor = PlanEditor(plan: plan)
        XCTAssertEqual(editor.items.count, 3)
        XCTAssertEqual(editor.items.first { $0.kind == .ac }?.roomName, "Bedroom")
    }

    func testAPlanTheStoreAcceptsAndAScanThatRoundTrips() throws {
        let plan = try build()
        XCTAssertNoThrow(try PlanStore.validate(PlanStore.encode(plan)))
        let data = try JSONEncoder().encode(SampleScan.scan)
        XCTAssertEqual(try JSONDecoder().decode(RoomScan.self, from: data), SampleScan.scan)
    }

    func testTooLittleScannedIsNoHome() {
        XCTAssertNil(ScanLayout.plan(from: RoomScan(), name: "Empty"))
        let wall = RoomScan(rooms: [RoomScan.Room(walls: [SampleScan.surface(.wall, (0, 0), (3, 0))])])
        XCTAssertNil(ScanLayout.plan(from: wall, name: "One wall"))
    }

    /// `ROOM_SCAN_SAMPLE=<file> swift test --filter RoomScanTests` saves the sample scan, for
    /// the iPhone app's review screen in the simulator: `HOUSE_SCAN_FIXTURE=<file> scripts/ios-sim.sh`.
    func testSavingTheSampleForTheSimulator() throws {
        guard let path = ProcessInfo.processInfo.environment["ROOM_SCAN_SAMPLE"] else { return }
        try JSONEncoder().encode(SampleScan.scan).write(to: URL(fileURLWithPath: path))
    }

    func testAScanBecomesAnotherFloor() throws {
        let scanned = try build()
        var home = PlanEditor.blank(name: "House")
        home["lights"] = [["id": "living-room.light", "name": "Old", "room": "living", "type": "ceiling", "pos": [1, 1]]]
        let plan = ScanLayout.adding(scanned, asFloor: "First floor", to: home)
        let levels = plan["levels"] as! [[String: Any]]
        XCTAssertEqual(levels.map { $0["id"] as? String }, ["main", "floor2"])
        XCTAssertEqual(levels[1]["name"] as? String, "First floor")
        let rooms = plan["rooms"] as! [[String: Any]]
        XCTAssertEqual(rooms.count, 5)
        XCTAssertNil(rooms[0]["level"])
        XCTAssertEqual(Set(rooms.dropFirst().compactMap { $0["level"] as? String }), ["floor2"])
        // A lamp id the home already had gets a number, and keeps its room.
        let lights = plan["lights"] as! [[String: Any]]
        XCTAssertEqual(lights.map { $0["id"] as? String }, ["living-room.light", "living-room.light2", "living-room.light3"])
        XCTAssertEqual(lights[1]["room"] as? String, "living-room")
        XCTAssertEqual(PlanEditor(plan: plan).levels.count, 2)
    }
}
