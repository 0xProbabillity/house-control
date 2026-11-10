import Foundation

/// A LiDAR scan of a home as the iPhone's RoomPlan saw it, in plain numbers: walls, doors,
/// windows and furniture in the AR session's world space (metres, y up), plus the lamps and
/// ACs the user pointed at while scanning. `ScanLayout` turns it into a floor plan.
/// Kept free of RoomPlan so it can be saved, tested and rebuilt anywhere.
public struct RoomScan: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var z: Double
        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    public enum SurfaceKind: String, Codable, Sendable {
        case wall, door, window, opening
    }

    /// A wall, door, window or opening: a flat rectangle standing upright.
    public struct Surface: Codable, Equatable, Sendable {
        public var kind: SurfaceKind
        public var center: Point
        /// The horizontal direction its width runs along (x and z of the surface's own x axis).
        public var axisX: Double
        public var axisZ: Double
        public var width: Double
        public var height: Double
        public init(kind: SurfaceKind, center: Point, axisX: Double, axisZ: Double, width: Double, height: Double) {
            self.kind = kind
            self.center = center
            self.axisX = axisX
            self.axisZ = axisZ
            self.width = width
            self.height = height
        }
    }

    /// A piece of furniture or an appliance: a box.
    public struct Object: Codable, Equatable, Sendable {
        /// RoomPlan's category: "bed", "sofa", "table", "storage", "stove"…
        public var category: String
        /// Its attribute, where RoomPlan tells one: a "dining" or "coffee" table, a "shelf"…
        public var kind: String?
        public var center: Point
        /// The horizontal direction of its width (its own x axis).
        public var axisX: Double
        public var axisZ: Double
        public var width: Double
        public var height: Double
        public var depth: Double
        public init(category: String, kind: String? = nil, center: Point, axisX: Double, axisZ: Double,
                    width: Double, height: Double, depth: Double) {
            self.category = category
            self.kind = kind
            self.center = center
            self.axisX = axisX
            self.axisZ = axisZ
            self.width = width
            self.height = height
            self.depth = depth
        }
    }

    /// Where RoomPlan thinks a kitchen, a bedroom… is.
    public struct Section: Codable, Equatable, Sendable {
        /// "livingRoom", "bedroom", "bathroom", "kitchen", "diningRoom" or "unidentified".
        public var label: String
        public var center: Point
        public init(label: String, center: Point) {
            self.label = label
            self.center = center
        }
    }

    /// One room, scanned in one go.
    public struct Room: Codable, Equatable, Sendable {
        public var walls: [Surface]
        /// Doors, windows and openings.
        public var openings: [Surface]
        public var objects: [Object]
        public var sections: [Section]
        /// The corners of its floor, where RoomPlan found them: the outline when there are too few walls.
        public var floor: [Point]
        public init(walls: [Surface] = [], openings: [Surface] = [], objects: [Object] = [],
                    sections: [Section] = [], floor: [Point] = []) {
            self.walls = walls
            self.openings = openings
            self.objects = objects
            self.sections = sections
            self.floor = floor
        }
    }

    /// A real device of a connected platform, as `DeviceHub.allDevices` lists it.
    public struct Device: Codable, Equatable, Sendable {
        public var service: String
        public var id: String
        public var name: String
        public var capabilities: [String]
        public var min: Double?
        public var max: Double?
        public init(service: String, id: String, name: String, capabilities: [String] = [], min: Double? = nil, max: Double? = nil) {
            self.service = service
            self.id = id
            self.name = name
            self.capabilities = capabilities
            self.min = min
            self.max = max
        }

        /// A device from `DeviceHub.allDevices`.
        public init?(_ raw: [String: Any]) {
            guard let service = raw["service"] as? String, let id = raw["id"] as? String else { return nil }
            self.init(service: service, id: id, name: raw["name"] as? String ?? id,
                      capabilities: raw["capabilities"] as? [String] ?? [],
                      min: (raw["min"] as? NSNumber)?.doubleValue, max: (raw["max"] as? NSNumber)?.doubleValue)
        }

        /// The form `PlanEditor.link` takes.
        var dictionary: [String: Any] {
            var out: [String: Any] = ["service": service, "id": id, "name": name, "capabilities": capabilities]
            if let min, let max { out["min"] = min; out["max"] = max }
            return out
        }
    }

    /// A lamp or an AC the user pointed at while scanning.
    public struct Tag: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// "light" or "ac".
        public var kind: String
        public var name: String
        public var position: Point
        /// The real device it is, or nil for one to link later (simulated until then).
        public var device: Device?
        public init(id: String = UUID().uuidString, kind: String, name: String, position: Point, device: Device? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.position = position
            self.device = device
        }
    }

    public var rooms: [Room]
    public var tags: [Tag]

    public init(rooms: [Room] = [], tags: [Tag] = []) {
        self.rooms = rooms
        self.tags = tags
    }
}

/// Turns a `RoomScan` into a floor plan of House Control's kind: rooms are rectangles on a
/// square grid, openings sit on their edges (see `web/src/config.js`). The scan is turned so
/// its walls run along x and z, every room's outline is cut into rectangles along its walls,
/// the gaps a wall's thickness leaves between two rooms are closed, and furniture and the
/// tagged devices are placed in the room they stand in.
public enum ScanLayout {
    /// The new home, or nil when the scan holds no room big enough to draw.
    public static func plan(from scan: RoomScan, name: String) -> [String: Any]? {
        var builder = Builder(scan: scan)
        return builder.build(name: name)
    }

    /// Puts the rooms, furniture and devices of `scanned` (a plan made by `plan(from:)`) on a new
    /// floor of `home`, called `floorName`, above the others. Ids already used get a number.
    public static func adding(_ scanned: [String: Any], asFloor floorName: String, to home: [String: Any]) -> [String: Any] {
        var plan = home
        var levels = home["levels"] as? [[String: Any]] ?? []
        if levels.isEmpty { levels = [["id": "main", "name": "Ground floor"]] }
        var taken = Set<String>()
        for key in ["rooms", "lights", "acs", "scenes"] {
            for entry in home[key] as? [[String: Any]] ?? [] { if let id = entry["id"] as? String { taken.insert(id) } }
        }
        let level = unique("floor\(levels.count + 1)", in: Set(levels.compactMap { $0["id"] as? String }))
        var newLevel: [String: Any] = ["id": level, "name": floorName]
        if let height = scanned["wallHeight"] { newLevel["wallHeight"] = height }
        levels.append(newLevel)
        plan["levels"] = levels

        var renamed: [String: String] = [:]
        func rename(_ id: String) -> String {
            let new = unique(id, in: taken)
            taken.insert(new)
            renamed[id] = new
            return new
        }
        var rooms = home["rooms"] as? [[String: Any]] ?? []
        for var room in scanned["rooms"] as? [[String: Any]] ?? [] {
            room["id"] = rename(room["id"] as? String ?? "room")
            room["level"] = level
            rooms.append(room)
        }
        plan["rooms"] = rooms
        for key in ["openings", "furniture"] {
            var list = home[key] as? [[String: Any]] ?? []
            for var item in scanned[key] as? [[String: Any]] ?? [] {
                item["level"] = level
                list.append(item)
            }
            plan[key] = list
        }
        for key in ["lights", "acs"] {
            var list = home[key] as? [[String: Any]] ?? []
            for var item in scanned[key] as? [[String: Any]] ?? [] {
                item["id"] = rename(item["id"] as? String ?? key)
                if let room = item["room"] as? String { item["room"] = renamed[room] ?? room }
                list.append(item)
            }
            plan[key] = list
        }
        return plan
    }

    /// `base`, or `base` with the next free number ("light", "light2", "light3"…).
    static func unique(_ base: String, in taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var stem = Substring(base)
        while let last = stem.last, last.isNumber { stem.removeLast() }
        if stem.isEmpty { stem = Substring(base) }
        var i = 2
        while taken.contains("\(stem)\(i)") { i += 1 }
        return "\(stem)\(i)"
    }
}

// MARK: - Building

private struct V2 {
    var x: Double
    var z: Double
    static func + (a: V2, b: V2) -> V2 { V2(x: a.x + b.x, z: a.z + b.z) }
    static func - (a: V2, b: V2) -> V2 { V2(x: a.x - b.x, z: a.z - b.z) }
    static func * (a: V2, k: Double) -> V2 { V2(x: a.x * k, z: a.z * k) }
    func dot(_ b: V2) -> Double { x * b.x + z * b.z }
    var length: Double { (x * x + z * z).squareRoot() }
    var unit: V2 { length > 1e-9 ? self * (1 / length) : V2(x: 1, z: 0) }
    /// Turned a quarter to the left.
    var perp: V2 { V2(x: -z, z: x) }
}

/// A wall seen from above, once the scan is square: along x at z = c (horizontal) or along z at x = c.
private struct Segment {
    var horizontal: Bool
    var c: Double
    var a: Double
    var b: Double
}

private struct Rect {
    var x0: Double
    var z0: Double
    var x1: Double
    var z1: Double
    /// The scanned room it was cut from.
    var group: Int
    var name = ""
    var id = ""
    var w: Double { x1 - x0 }
    var d: Double { z1 - z0 }
    var area: Double { w * d }
    var center: V2 { V2(x: (x0 + x1) / 2, z: (z0 + z1) / 2) }
    func contains(_ p: V2, margin: Double = 0) -> Bool {
        p.x >= x0 - margin && p.x <= x1 + margin && p.z >= z0 - margin && p.z <= z1 + margin
    }
    func distance(to p: V2) -> Double {
        let dx = max(x0 - p.x, 0, p.x - x1)
        let dz = max(z0 - p.z, 0, p.z - z1)
        return (dx * dx + dz * dz).squareRoot()
    }
    /// How far from `p` (inside) a ray in direction `dir` leaves the rectangle.
    func exit(from p: V2, along dir: V2) -> Double {
        var t = Double.infinity
        if dir.x > 1e-6 { t = min(t, (x1 - p.x) / dir.x) }
        if dir.x < -1e-6 { t = min(t, (x0 - p.x) / dir.x) }
        if dir.z > 1e-6 { t = min(t, (z1 - p.z) / dir.z) }
        if dir.z < -1e-6 { t = min(t, (z0 - p.z) / dir.z) }
        return max(0, t)
    }
}

/// Sums over a grid of 0/1 values, for checking a rectangle of cells at once.
private struct Prefix {
    private var sums: [[Int]]
    init(_ grid: [[Bool]], columns: Int, rows: Int) {
        sums = Array(repeating: Array(repeating: 0, count: rows + 1), count: columns + 1)
        guard columns > 0, rows > 0 else { return }
        for i in 0..<columns {
            for j in 0..<rows {
                let v = i < grid.count && j < grid[i].count && grid[i][j] ? 1 : 0
                sums[i + 1][j + 1] = v + sums[i][j + 1] + sums[i + 1][j] - sums[i][j]
            }
        }
    }
    /// Cells i0...i1 × j0...j1; an empty range sums to 0.
    func sum(_ i0: Int, _ i1: Int, _ j0: Int, _ j1: Int) -> Int {
        guard i0 <= i1, j0 <= j1 else { return 0 }
        return sums[i1 + 1][j1 + 1] - sums[i0][j1 + 1] - sums[i1 + 1][j0] + sums[i0][j0]
    }
}

private struct Builder {
    let scan: RoomScan
    /// The scan is turned by -angle so its walls run along x and z.
    private var angle = 0.0
    private var offset = V2(x: 0, z: 0)
    private var floorY = 0.0
    private var height = 2.6
    private var rects: [Rect] = []
    /// Each scanned room's walls, square and moved like the rooms.
    private var walls: [[Segment]] = []

    init(scan: RoomScan) { self.scan = scan }

    // Smallest room worth drawing.
    static let minSide = 0.5
    static let minArea = 0.8

    mutating func build(name: String) -> [String: Any]? {
        let allWalls = scan.rooms.flatMap(\.walls).filter { $0.width >= 0.3 }
        angle = Self.dominantAngle(allWalls)
        floorY = Self.median(allWalls.map { $0.center.y - $0.height / 2 })
            ?? scan.rooms.flatMap(\.floor).map(\.y).min() ?? 0
        height = min(4, max(2.2, ((Self.median(allWalls.map(\.height)) ?? 2.6) * 20).rounded() / 20))

        for (group, room) in scan.rooms.enumerated() {
            let segments = room.walls.filter { $0.width >= 0.3 }.map(segment)
            walls.append(segments)
            rects += outline(of: room, segments: segments, group: group)
        }
        guard !rects.isEmpty else { return nil }
        closeGaps()
        rects = rects.filter { $0.w >= Self.minSide - 0.1 && $0.d >= Self.minSide - 0.1 }
        guard !rects.isEmpty else { return nil }

        // The home starts at (0, 0), in whole centimetres.
        offset = V2(x: rects.map(\.x0).min() ?? 0, z: rects.map(\.z0).min() ?? 0)
        for i in rects.indices {
            rects[i].x0 = cm(rects[i].x0 - offset.x)
            rects[i].x1 = cm(rects[i].x1 - offset.x)
            rects[i].z0 = cm(rects[i].z0 - offset.z)
            rects[i].z1 = cm(rects[i].z1 - offset.z)
        }
        for g in walls.indices {
            walls[g] = walls[g].map { s in
                let shift = s.horizontal ? offset.x : offset.z
                return Segment(horizontal: s.horizontal, c: s.c - (s.horizontal ? offset.z : offset.x), a: s.a - shift, b: s.b - shift)
            }
        }
        nameRooms()

        let furniture = self.furniture()
        var plan: [String: Any] = [
            "version": 1,
            "name": name,
            "wallHeight": height,
            "interiorWallHeight": 1.25,
            "camera": ["azimuth": 34, "elevation": 47],
            "rooms": rects.map { r -> [String: Any] in
                ["id": r.id, "name": r.name, "rect": [r.x0, r.z0, cm(r.w), cm(r.d)], "floor": Self.floorKind(r.name)]
            },
            "openings": openings(),
            "furniture": furniture,
            "lights": [[String: Any]](),
            "acs": [[String: Any]](),
            "scenes": PlanEditor.blank(name: name)["scenes"] ?? [],
        ]
        placeTags(in: &plan)
        return plan
    }

    // MARK: Squaring up

    /// The direction most walls run in, folded into a quarter turn and weighted by length.
    static func dominantAngle(_ walls: [RoomScan.Surface]) -> Double {
        var c = 0.0, s = 0.0
        for wall in walls {
            let a = atan2(wall.axisZ, wall.axisX)
            c += wall.width * cos(4 * a)
            s += wall.width * sin(4 * a)
        }
        return abs(c) < 1e-9 && abs(s) < 1e-9 ? 0 : atan2(s, c) / 4
    }

    /// A point of the scan, turned square (not yet moved to the origin).
    func turn(_ x: Double, _ z: Double) -> V2 {
        V2(x: x * cos(angle) + z * sin(angle), z: -x * sin(angle) + z * cos(angle))
    }

    /// A point of the scan where it ends up in the plan.
    func place(_ p: RoomScan.Point) -> V2 { turn(p.x, p.z) - offset }

    func direction(_ x: Double, _ z: Double) -> V2 { turn(x, z).unit }

    func segment(_ wall: RoomScan.Surface) -> Segment {
        let c = turn(wall.center.x, wall.center.z)
        let d = direction(wall.axisX, wall.axisZ)
        let p1 = c - d * (wall.width / 2), p2 = c + d * (wall.width / 2)
        if abs(d.x) >= abs(d.z) {
            return Segment(horizontal: true, c: (p1.z + p2.z) / 2, a: min(p1.x, p2.x), b: max(p1.x, p2.x))
        }
        return Segment(horizontal: false, c: (p1.x + p2.x) / 2, a: min(p1.z, p2.z), b: max(p1.z, p2.z))
    }

    // MARK: Room outlines

    /// The rectangles a scanned room is made of: its walls make a grid, the cells walled in on
    /// all four sides are inside, and those are joined into as few rectangles as the walls
    /// between them allow.
    func outline(of room: RoomScan.Room, segments: [Segment], group: Int) -> [Rect] {
        let vertical = segments.filter { !$0.horizontal }
        let horizontal = segments.filter(\.horizontal)
        if vertical.count >= 2, horizontal.count >= 2 {
            let xs = Self.cluster(vertical.map(\.c), within: 0.15)
            let zs = Self.cluster(horizontal.map(\.c), within: 0.15)
            if xs.count >= 2, zs.count >= 2 {
                let found = grid(xs: xs, zs: zs, vertical: vertical, horizontal: horizontal, group: group)
                if !found.isEmpty { return found }
            }
        }
        // Too few walls: the floor's outline, or what the walls span.
        var points = room.floor.map { turn($0.x, $0.z) }
        if points.count < 3 {
            points = segments.flatMap { s in
                s.horizontal ? [V2(x: s.a, z: s.c), V2(x: s.b, z: s.c)] : [V2(x: s.c, z: s.a), V2(x: s.c, z: s.b)]
            }
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minZ = points.map(\.z).min(), let maxZ = points.map(\.z).max(),
              maxX - minX >= Self.minSide, maxZ - minZ >= Self.minSide else { return [] }
        return [Rect(x0: minX, z0: minZ, x1: maxX, z1: maxZ, group: group)]
    }

    private func grid(xs: [Double], zs: [Double], vertical: [Segment], horizontal: [Segment], group: Int) -> [Rect] {
        let n = xs.count - 1, m = zs.count - 1
        let reach = 0.3 // walls rarely meet exactly in the corners
        func covers(_ s: Segment, _ t: Double) -> Bool { s.a - reach <= t && t <= s.b + reach }
        var inside = Array(repeating: Array(repeating: false, count: m), count: n)
        for i in 0..<n {
            for j in 0..<m {
                let cx = (xs[i] + xs[i + 1]) / 2, cz = (zs[j] + zs[j + 1]) / 2
                inside[i][j] = vertical.contains { $0.c > cx && covers($0, cz) }
                    && vertical.contains { $0.c < cx && covers($0, cz) }
                    && horizontal.contains { $0.c > cz && covers($0, cx) }
                    && horizontal.contains { $0.c < cz && covers($0, cx) }
            }
        }
        // A wall on a grid line between two cells keeps them in separate rectangles.
        func index(_ v: Double, _ lines: [Double]) -> Int {
            lines.indices.min { abs(lines[$0] - v) < abs(lines[$1] - v) } ?? 0
        }
        var wallX = Array(repeating: Array(repeating: false, count: m), count: n) // line xs[i] (1..<n) beside row j
        var wallZ = Array(repeating: Array(repeating: false, count: m), count: n) // line zs[j] (1..<m) beside column i
        for s in vertical {
            let i = index(s.c, xs)
            guard i > 0, i < n else { continue }
            for j in 0..<m where s.a - 0.05 <= (zs[j] + zs[j + 1]) / 2 && (zs[j] + zs[j + 1]) / 2 <= s.b + 0.05 { wallX[i][j] = true }
        }
        for s in horizontal {
            let j = index(s.c, zs)
            guard j > 0, j < m else { continue }
            for i in 0..<n where s.a - 0.05 <= (xs[i] + xs[i + 1]) / 2 && (xs[i] + xs[i + 1]) / 2 <= s.b + 0.05 { wallZ[i][j] = true }
        }
        let blockedX = Prefix(wallX, columns: n, rows: m)
        let blockedZ = Prefix(wallZ, columns: n, rows: m)

        var out: [Rect] = []
        while true {
            let filled = Prefix(inside, columns: n, rows: m)
            var best: (area: Double, i0: Int, i1: Int, j0: Int, j1: Int)?
            for i0 in 0..<n {
                for j0 in 0..<m where inside[i0][j0] {
                    for i1 in i0..<n {
                        guard filled.sum(i0, i1, j0, j0) == i1 - i0 + 1 else { break }
                        for j1 in j0..<m {
                            let cells = (i1 - i0 + 1) * (j1 - j0 + 1)
                            guard filled.sum(i0, i1, j0, j1) == cells else { break }
                            // Walls inside: on lines i0+1...i1 (rows j0...j1), j0+1...j1 (columns i0...i1).
                            if blockedX.sum(i0 + 1, i1, j0, j1) > 0 || blockedZ.sum(i0, i1, j0 + 1, j1) > 0 { break }
                            let area = (xs[i1 + 1] - xs[i0]) * (zs[j1 + 1] - zs[j0])
                            if area > best?.area ?? 0 { best = (area, i0, i1, j0, j1) }
                        }
                    }
                }
            }
            guard let b = best else { break }
            for i in b.i0...b.i1 { for j in b.j0...b.j1 { inside[i][j] = false } }
            let rect = Rect(x0: xs[b.i0], z0: zs[b.j0], x1: xs[b.i1 + 1], z1: zs[b.j1 + 1], group: group)
            if rect.w >= Self.minSide, rect.d >= Self.minSide, rect.area >= Self.minArea { out.append(rect) }
        }
        return out
    }

    /// Values closer than `within` to the previous one join it; each group becomes its mean.
    static func cluster(_ values: [Double], within: Double, span: Double = .infinity) -> [Double] {
        var groups: [[Double]] = []
        for v in values.sorted() {
            if let last = groups.last?.last, v - last < within, v - groups[groups.count - 1][0] <= span {
                groups[groups.count - 1].append(v)
            } else {
                groups.append([v])
            }
        }
        return groups.map { $0.reduce(0, +) / Double($0.count) }
    }

    /// Two rooms scanned one after the other stand a wall's thickness apart, and a little off
    /// one another: edges that close together become one, so the rooms share a wall.
    mutating func closeGaps() {
        let xs = Self.cluster(rects.flatMap { [$0.x0, $0.x1] }, within: 0.32, span: 0.45)
        let zs = Self.cluster(rects.flatMap { [$0.z0, $0.z1] }, within: 0.32, span: 0.45)
        func snap(_ v: Double, _ lines: [Double]) -> Double {
            lines.min { abs($0 - v) < abs($1 - v) } ?? v
        }
        for i in rects.indices {
            rects[i].x0 = snap(rects[i].x0, xs)
            rects[i].x1 = snap(rects[i].x1, xs)
            rects[i].z0 = snap(rects[i].z0, zs)
            rects[i].z1 = snap(rects[i].z1, zs)
        }
    }

    // MARK: Names

    static let labels = ["livingRoom": "Living room", "bedroom": "Bedroom", "bathroom": "Bathroom",
                         "kitchen": "Kitchen", "diningRoom": "Dining room"]

    mutating func nameRooms() {
        var names: [String] = []
        for (index, rect) in rects.enumerated() {
            let room = scan.rooms[rect.group]
            let sections = room.sections.filter { Self.labels[$0.label] != nil }
            // A label RoomPlan put inside it, what stands in it, or the nearest label of its room.
            var name = sections.first { rect.contains(place($0.center), margin: 0.2) }.flatMap { Self.labels[$0.label] }
            if name == nil { name = guessName(rect, objects: room.objects) }
            if name == nil {
                name = sections.min { rect.distance(to: place($0.center)) < rect.distance(to: place($1.center)) }
                    .flatMap { Self.labels[$0.label] }
            }
            names.append(name ?? "Room")
            rects[index].name = names.last!
        }
        // "Bedroom", "Bedroom 2"…
        var seen: [String: Int] = [:]
        var ids = Set<String>()
        for i in rects.indices {
            let base = rects[i].name
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            if names.filter({ $0 == base }).count > 1, count > 1 { rects[i].name = "\(base) \(count)" }
            let id = ScanLayout.unique(PlanEditor.slug(rects[i].name), in: ids)
            ids.insert(id)
            rects[i].id = id
        }
    }

    func guessName(_ rect: Rect, objects: [RoomScan.Object]) -> String? {
        let here = Set(objects.filter { rect.contains(place($0.center), margin: 0.1) }.map(\.category))
        if !here.isDisjoint(with: ["toilet", "bathtub"]) { return "Bathroom" }
        if !here.isDisjoint(with: ["stove", "oven", "refrigerator", "dishwasher"]) { return "Kitchen" }
        if here.contains("bed") { return "Bedroom" }
        if !here.isDisjoint(with: ["sofa", "television"]) { return "Living room" }
        if here.contains("table") { return "Dining room" }
        if min(rect.w, rect.d) <= 1.6, max(rect.w, rect.d) >= 2 * min(rect.w, rect.d) { return "Hallway" }
        return nil
    }

    static func floorKind(_ name: String) -> String {
        if name.hasPrefix("Bathroom") { return "tile" }
        if name.hasPrefix("Kitchen") { return "stone" }
        if name.hasPrefix("Bedroom") { return "walnut" }
        return "oak"
    }

    func cm(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: Openings

    private struct Edge {
        var horizontal: Bool
        var c: Double
        var a: Double
        var b: Double
    }

    private var edges: [Edge] {
        rects.flatMap { r in [
            Edge(horizontal: true, c: r.z0, a: r.x0, b: r.x1), Edge(horizontal: true, c: r.z1, a: r.x0, b: r.x1),
            Edge(horizontal: false, c: r.x0, a: r.z0, b: r.z1), Edge(horizontal: false, c: r.x1, a: r.z0, b: r.z1),
        ] }
    }

    /// Doors, windows and openings on the room edges they were found on, and open passages
    /// between the rectangles of one room where no wall stands.
    func openings() -> [[String: Any]] {
        struct Found {
            var type: String
            var horizontal: Bool
            var c: Double
            var a: Double
            var b: Double
            var sill = 0.0
            var head = 0.0
        }
        var found: [Found] = []
        let edges = self.edges
        for room in scan.rooms {
            for surface in room.openings where surface.width >= 0.3 {
                let center = place(surface.center)
                let d = direction(surface.axisX, surface.axisZ)
                let horizontal = abs(d.x) >= abs(d.z)
                let along = horizontal ? center.x : center.z
                let across = horizontal ? center.z : center.x
                let candidates = edges.filter { $0.horizontal == horizontal && abs($0.c - across) < 0.5 && along >= $0.a - 0.15 && along <= $0.b + 0.15 }
                guard let edge = candidates.min(by: { abs($0.c - across) < abs($1.c - across) }) else { continue }
                let a = max(edge.a, along - surface.width / 2), b = min(edge.b, along + surface.width / 2)
                guard b - a >= 0.3 else { continue }
                var item = Found(type: surface.kind == .window ? "window" : surface.kind == .door ? "door" : "open",
                                 horizontal: horizontal, c: edge.c, a: cm(a), b: cm(b))
                if surface.kind == .window {
                    let bottom = surface.center.y - surface.height / 2 - floorY
                    item.sill = cm(min(max(bottom, 0), height - 0.3))
                    item.head = cm(min(max(bottom + surface.height, item.sill + 0.2), height))
                }
                // The same door seen from both rooms.
                if let i = found.firstIndex(where: { $0.type == item.type && $0.horizontal == horizontal && $0.c == item.c
                    && min($0.b, item.b) - max($0.a, item.a) > 0.5 * min($0.b - $0.a, item.b - item.a) }) {
                    found[i].a = min(found[i].a, item.a)
                    found[i].b = max(found[i].b, item.b)
                } else {
                    found.append(item)
                }
            }
        }
        // Rectangles cut from one room meet without a wall between them.
        for (i, r) in rects.enumerated() {
            for s in rects[(i + 1)...] where s.group == r.group {
                var shared: [Edge] = []
                for (x, other) in [(r.x1, s.x0), (r.x0, s.x1)] where x == other {
                    let a = max(r.z0, s.z0), b = min(r.z1, s.z1)
                    if b - a >= 0.3 { shared.append(Edge(horizontal: false, c: x, a: a, b: b)) }
                }
                for (z, other) in [(r.z1, s.z0), (r.z0, s.z1)] where z == other {
                    let a = max(r.x0, s.x0), b = min(r.x1, s.x1)
                    if b - a >= 0.3 { shared.append(Edge(horizontal: true, c: z, a: a, b: b)) }
                }
                for edge in shared where !walled(edge, group: r.group) {
                    found.append(Found(type: "open", horizontal: edge.horizontal, c: edge.c, a: edge.a, b: edge.b))
                }
            }
        }
        return found.map { o in
            let from = o.horizontal ? [o.a, o.c] : [o.c, o.a]
            let to = o.horizontal ? [o.b, o.c] : [o.c, o.b]
            var out: [String: Any] = ["type": o.type, "from": from, "to": to]
            if o.type == "window" { out["sill"] = o.sill; out["head"] = o.head }
            return out
        }
    }

    /// True when one of the room's walls runs along the middle of `edge`.
    private func walled(_ edge: Edge, group: Int) -> Bool {
        let mid = (edge.a + edge.b) / 2
        return walls[group].contains { $0.horizontal == edge.horizontal && abs($0.c - edge.c) < 0.25 && $0.a <= mid && mid <= $0.b }
    }

    // MARK: Furniture

    private struct Piece {
        var type: String
        var center: V2
        /// Degrees, as the plan's "rot": 0 faces +z with its back to -z.
        var rot: Double
        var width: Double
        var extra: [String: Any] = [:]
        var room: Int
    }

    func room(at p: V2) -> Int? {
        if let i = rects.firstIndex(where: { $0.contains(p, margin: 0.05) }) { return i }
        return rects.indices.min { rects[$0].distance(to: p) < rects[$1].distance(to: p) }
    }

    /// The scan's furniture as House Control's: a bed is a bed, a stove and a sink in a row are
    /// a kitchen, chairs round a dining table are its chairs. Each stands with its back to the
    /// wall nearest behind it.
    func furniture() -> [[String: Any]] {
        let objects = scan.rooms.flatMap(\.objects)
        var pieces: [Piece] = []
        var usedChairs = Set<Int>()
        let kitchenRooms = Set(objects.filter { ["stove", "oven", "refrigerator", "dishwasher"].contains($0.category) }
            .compactMap { room(at: place($0.center)) })

        for (index, object) in objects.enumerated() {
            let center = place(object.center)
            guard let roomIndex = room(at: center) else { continue }
            let rect = rects[roomIndex]
            let inKitchen = kitchenRooms.contains(roomIndex) || rect.name.hasPrefix("Kitchen")
            var axis = direction(object.axisX, object.axisZ)
            var w = object.width, d = object.depth
            let h = object.height
            // Which of its sides is the width: the long one for a sofa, the short one for a bed.
            func long() { if d > w * 1.15 { axis = axis.perp; swap(&w, &d) } }
            func short() { if w > d * 1.15 { axis = axis.perp; swap(&w, &d) } }
            var type: String
            var width: Double? = nil
            var extra: [String: Any] = [:]
            var againstWall = true
            switch object.category {
            case "sofa":
                long(); type = "sofa"; width = clamp(w, 1.0, 3.6)
            case "bed":
                short(); type = "bed"; width = clamp(w, 0.9, 2.2)
            case "television":
                long(); type = "tv"; width = clamp(w, 0.6, 2.4)
            case "refrigerator":
                type = "fridge"
            case "stove", "oven", "dishwasher":
                long(); type = "kitchen"; width = clamp(w, 0.45, 6); extra["upper"] = true
            case "sink":
                long()
                if inKitchen { type = "kitchen"; width = clamp(w, 0.45, 6); extra["upper"] = true } else { type = "vanity"; width = clamp(w, 0.5, 1.8) }
            case "toilet":
                short(); type = "toilet"
            case "bathtub":
                long(); type = "bathtub"
            case "stairs":
                short(); type = "stairs"; width = clamp(w, 0.7, 1.6); extra["depth"] = clamp(d, 2, 4.5)
            case "storage":
                long()
                if object.kind == "shelf" || (d < 0.4 && h > 1.1) {
                    type = "bookshelf"; width = clamp(w, 0.4, 2.5); extra["height"] = cm(clamp(h, 0.8, 2.4))
                } else if h >= 1.5 {
                    type = "wardrobe"; width = clamp(w, 0.6, 3.5); extra["height"] = cm(clamp(h, 1.5, 2.6))
                } else if inKitchen {
                    type = "kitchen"; width = clamp(w, 0.45, 6); extra["upper"] = true
                } else if w < 0.65, h < 0.8 {
                    type = "nightstand"
                } else if h >= 0.6 {
                    type = "dresser"; width = clamp(w, 0.6, 2.2)
                } else {
                    type = "sideboard"; width = clamp(w, 0.8, 3)
                }
            case "table":
                long()
                if object.kind == "coffee" || h < 0.55 {
                    type = "coffeeTable"; width = clamp(w, 0.6, 1.8); againstWall = false
                } else if object.kind == "dining" || d >= 0.75 {
                    type = "diningSet"; width = clamp(w, 0.9, 3); againstWall = false
                    let chairs = objects.indices.filter { i in
                        objects[i].category == "chair" && !usedChairs.contains(i)
                            && (place(objects[i].center) - center).length < max(1.3, w / 2 + 0.7)
                    }
                    usedChairs.formUnion(chairs)
                    extra["chairs"] = min(8, max(2, chairs.count))
                } else {
                    type = "desk"; width = clamp(w, 0.8, 2.2)
                }
            case "chair":
                guard object.kind == nil || object.kind == "unidentified", w >= 0.6, !usedChairs.contains(index) else { continue }
                type = "armchair"
            default:
                continue // washer, fireplace: nothing like them in the library
            }
            if object.category == "chair" {
                // Chairs left over once the tables took theirs.
                if objects.indices.contains(where: { objects[$0].category == "table" && (place(objects[$0].center) - center).length < 1.2 }) { continue }
            }
            var rot: Double
            if againstWall {
                // Back to the nearest wall: try both sides across its width (all four if it is square).
                var backs = [axis.perp, axis.perp * -1]
                if abs(w - d) < 0.15 { backs += [axis, axis * -1] }
                let back = backs.min { rect.exit(from: center, along: $0) < rect.exit(from: center, along: $1) }!
                rot = atan2(-back.x, -back.z) * 180 / .pi
            } else {
                rot = atan2(-axis.z, axis.x) * 180 / .pi
            }
            rot = Self.snap(rot)
            pieces.append(Piece(type: type, center: center, rot: rot, width: width ?? 0, extra: extra, room: roomIndex))
        }
        pieces = mergeKitchens(pieces)
        return pieces.map { p in
            var out: [String: Any] = ["type": p.type, "pos": [cm(p.center.x), cm(p.center.z)]]
            if p.rot != 0 { out["rot"] = p.rot }
            if p.width > 0 { out["width"] = cm(p.width) }
            for (k, v) in p.extra { out[k] = v }
            return out
        }
    }

    /// A rotation in degrees, put square when it is nearly so, in -180...180.
    static func snap(_ degrees: Double) -> Double {
        var r = degrees.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        let square = (r / 90).rounded() * 90
        let out = abs(r - square) <= 12 ? square : r.rounded()
        return out == -180 ? 180 : (out == 0 ? 0 : out)
    }

    func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    /// Kitchen units side by side along one wall become one run of kitchen.
    private func mergeKitchens(_ pieces: [Piece]) -> [Piece] {
        var out = pieces.filter { $0.type != "kitchen" }
        var kitchens = pieces.filter { $0.type == "kitchen" }
        while let first = kitchens.first {
            kitchens.removeFirst()
            var run = first
            let r = run.rot * .pi / 180
            let ax = V2(x: cos(r), z: -sin(r)), front = V2(x: sin(r), z: cos(r))
            var lo = run.center.dot(ax) - run.width / 2, hi = run.center.dot(ax) + run.width / 2
            var depth = [run.center.dot(front)]
            var changed = true
            while changed {
                changed = false
                for (i, k) in kitchens.enumerated().reversed() where k.room == run.room && k.rot == run.rot {
                    let s = k.center.dot(ax), q = k.center.dot(front)
                    guard abs(q - depth[0]) < 0.35, s - k.width / 2 < hi + 0.5, s + k.width / 2 > lo - 0.5 else { continue }
                    lo = min(lo, s - k.width / 2)
                    hi = max(hi, s + k.width / 2)
                    depth.append(q)
                    kitchens.remove(at: i)
                    changed = true
                }
            }
            let q = depth.reduce(0, +) / Double(depth.count)
            run.center = ax * ((lo + hi) / 2) + front * q
            run.width = min(6, hi - lo)
            out.append(run)
        }
        return out
    }

    // MARK: Devices

    /// The lamps and ACs pointed at while scanning, in their rooms and linked to their devices.
    func placeTags(in plan: inout [String: Any]) {
        var lights: [[String: Any]] = []
        var acs: [[String: Any]] = []
        var taken = Set(rects.map(\.id))
        var links: [(String, [String: Any])] = []
        for tag in scan.tags {
            var p = place(tag.position)
            guard let index = room(at: p) else { continue }
            let rect = rects[index]
            let above = tag.position.y - floorY
            if tag.kind == "ac" {
                // On the nearest wall of its room.
                let sides: [(String, Double)] = [("north", p.z - rect.z0), ("south", rect.z1 - p.z), ("west", p.x - rect.x0), ("east", rect.x1 - p.x)]
                let wall = sides.min { abs($0.1) < abs($1.1) }!.0
                let along = { (v: Double, a: Double, b: Double) in b - a > 0.8 ? clamp(v, a + 0.4, b - 0.4) : (a + b) / 2 }
                switch wall {
                case "north": p = V2(x: along(p.x, rect.x0, rect.x1), z: rect.z0)
                case "south": p = V2(x: along(p.x, rect.x0, rect.x1), z: rect.z1)
                case "west": p = V2(x: rect.x0, z: along(p.z, rect.z0, rect.z1))
                default: p = V2(x: rect.x1, z: along(p.z, rect.z0, rect.z1))
                }
                let id = ScanLayout.unique("\(rect.id).ac", in: taken)
                taken.insert(id)
                var ac: [String: Any] = ["id": id, "name": tag.name, "room": rect.id, "wall": wall,
                                         "pos": [cm(p.x), cm(p.z)], "y": cm(clamp(above, 1.6, height - 0.25))]
                if let min = tag.device?.min, let max = tag.device?.max { ac["min"] = Int(min.rounded()); ac["max"] = Int(max.rounded()) }
                acs.append(ac)
                if let device = tag.device { links.append((id, device.dictionary)) }
            } else {
                p = V2(x: clamp(p.x, rect.x0 + 0.15, rect.x1 - 0.15), z: clamp(p.z, rect.z0 + 0.15, rect.z1 - 0.15))
                var type = PlanEditor.fixture(for: tag.name)
                if type == "ceiling" {
                    // What it is from how high it hangs.
                    if above >= height - 0.45 { type = "ceiling" }
                    else if above >= max(1.8, height - 1.2) { type = "pendant" }
                    else if above >= 1.05 { type = "floor" }
                    else { type = "table" }
                }
                let id = ScanLayout.unique("\(rect.id).light", in: taken)
                taken.insert(id)
                var light: [String: Any] = ["id": id, "name": tag.name, "room": rect.id, "type": type,
                                            "pos": [cm(p.x), cm(p.z)], "capabilities": ["brightness", "temp"]]
                if type == "pendant" { light["y"] = cm(clamp(above, 1.4, height - 0.3)) }
                if type == "strip" { light["length"] = 1.0; light["y"] = cm(clamp(above, 0.05, height - 0.05)) }
                lights.append(light)
                if let device = tag.device { links.append((id, device.dictionary)) }
            }
        }
        plan["lights"] = lights
        plan["acs"] = acs
        var editor = PlanEditor(plan: plan)
        for (id, device) in links { editor.link(id, to: device) }
        plan = editor.plan
    }
}
