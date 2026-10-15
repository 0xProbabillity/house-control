import Foundation

/// Small edits to a floor plan that the iPhone makes without the drawing editor: linking a
/// lamp or an AC to a real device, adding real devices to a room, starting a new home.
/// Works on the plan exactly as stored (`[String: Any]`), the same form the web editor
/// edits, and follows its rules (`web/src/editor/connections.js`, `web/src/config.js`).
public struct PlanEditor {
    public private(set) var plan: [String: Any]

    public init(plan: [String: Any]) { self.plan = plan }

    /// A lamp or an AC of the plan, for lists.
    public struct Item: Identifiable, Equatable {
        public let id: String
        public let kind: DeviceKind
        public let name: String
        public let room: String
        public let roomName: String
        /// `service` is "smartlife" for a Smart Life link.
        public let link: DeviceRef?
        /// An AC's thermometer.
        public let sensor: DeviceRef?
    }

    public struct DeviceRef: Hashable {
        public let service: String
        public let id: String
        public init(service: String, id: String) {
            self.service = service
            self.id = id
        }
    }

    public struct Room: Identifiable, Equatable {
        public let id: String
        public let name: String
    }

    // MARK: - Reading

    public var name: String { plan["name"] as? String ?? "Home" }

    public var rooms: [Room] {
        (plan["rooms"] as? [[String: Any]] ?? []).compactMap { room in
            guard let id = room["id"] as? String else { return nil }
            return Room(id: id, name: (room["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }
    }

    public var items: [Item] {
        let names = Dictionary(rooms.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [Item] = []
        for (kind, key) in [(DeviceKind.light, "lights"), (.ac, "acs")] {
            for device in plan[key] as? [[String: Any]] ?? [] {
                guard let id = device["id"] as? String else { continue }
                let room = device["room"] as? String ?? ""
                out.append(Item(id: id, kind: kind, name: (device["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                room: room, roomName: names[room] ?? room,
                                link: Self.link(of: device), sensor: Self.sensor(of: device)))
            }
        }
        return out
    }

    static func link(of device: [String: Any]) -> DeviceRef? {
        if let link = device["link"] as? [String: Any], let service = link["service"] as? String,
           let id = link["id"] as? String, !service.isEmpty, !id.isEmpty {
            return DeviceRef(service: service, id: id)
        }
        if let tuya = device["tuya"] as? [String: Any], let id = tuya["deviceId"] as? String, !id.isEmpty {
            return DeviceRef(service: "smartlife", id: id)
        }
        return nil
    }

    static func sensor(of device: [String: Any]) -> DeviceRef? {
        if let sensor = device["sensor"] as? [String: Any], let service = sensor["service"] as? String,
           let id = sensor["id"] as? String, !id.isEmpty {
            return DeviceRef(service: service, id: id)
        }
        if let tuya = device["tuya"] as? [String: Any], let id = tuya["sensorId"] as? String, !id.isEmpty {
            return DeviceRef(service: "smartlife", id: id)
        }
        return nil
    }

    /// Real devices already used by the plan, with the name of what uses them.
    public var usedDevices: [DeviceRef: String] {
        var out: [DeviceRef: String] = [:]
        for item in items {
            if let link = item.link { out[link] = item.name }
            if let sensor = item.sensor { out[sensor] = "\(item.name) · room" }
        }
        return out
    }

    // MARK: - Linking

    private func index(of id: String) -> (key: String, index: Int)? {
        for key in ["lights", "acs"] {
            if let i = (plan[key] as? [[String: Any]] ?? []).firstIndex(where: { $0["id"] as? String == id }) { return (key, i) }
        }
        return nil
    }

    private mutating func update(_ id: String, _ change: (inout [String: Any]) -> Void) {
        guard let (key, i) = index(of: id), var list = plan[key] as? [[String: Any]] else { return }
        change(&list[i])
        plan[key] = list
    }

    /// Links the lamp or AC `id` to `device` (a device as `DeviceHub.allDevices` lists it),
    /// or unlinks it (nil). A lamp takes over what the device can do, an AC its range.
    public mutating func link(_ id: String, to device: [String: Any]?) {
        update(id) { item in
            item["link"] = nil
            if var tuya = item["tuya"] as? [String: Any] {
                tuya["deviceId"] = nil
                item["tuya"] = tuya.isEmpty ? nil : tuya
            }
            guard let device, let service = device["service"] as? String, let target = device["id"] as? String else { return }
            if service == "smartlife" {
                var tuya = item["tuya"] as? [String: Any] ?? [:]
                tuya["deviceId"] = target
                item["tuya"] = tuya
            } else {
                item["link"] = ["service": service, "id": target]
                // A Smart Life thermometer only works beside a Smart Life AC.
                item["tuya"] = nil
            }
            let isAC = item["wall"] != nil
            if !isAC, let caps = device["capabilities"] as? [String] { item["capabilities"] = caps }
            if isAC, let min = (device["min"] as? NSNumber)?.doubleValue,
               let max = (device["max"] as? NSNumber)?.doubleValue {
                item["min"] = Int(min.rounded())
                item["max"] = Int(max.rounded())
            }
        }
    }

    /// Sets the thermometer of the AC `id` (a device with `kind` "sensor"), or removes it.
    public mutating func setSensor(_ id: String, to device: [String: Any]?) {
        update(id) { item in
            item["sensor"] = nil
            if var tuya = item["tuya"] as? [String: Any] {
                tuya["sensorId"] = nil
                item["tuya"] = tuya.isEmpty ? nil : tuya
            }
            guard let device, let service = device["service"] as? String, let target = device["id"] as? String else { return }
            if service == "smartlife" {
                var tuya = item["tuya"] as? [String: Any] ?? [:]
                tuya["sensorId"] = target
                item["tuya"] = tuya
            } else {
                item["sensor"] = ["service": service, "id": target]
            }
        }
    }

    // MARK: - Adding devices

    private var allIds: Set<String> {
        var ids = Set<String>()
        for key in ["rooms", "lights", "acs", "scenes"] {
            for entry in plan[key] as? [[String: Any]] ?? [] { if let id = entry["id"] as? String { ids.insert(id) } }
        }
        return ids
    }

    private func uniqueId(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base)\(i)") { i += 1 }
        return "\(base)\(i)"
    }

    private func rect(of room: String) -> [Double]? {
        guard let entry = (plan["rooms"] as? [[String: Any]] ?? []).first(where: { $0["id"] as? String == room }),
              let rect = entry["rect"] as? [NSNumber], rect.count == 4 else { return nil }
        return rect.map(\.doubleValue)
    }

    private static func fix(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// The fixture a lamp probably is, from its name.
    static func fixture(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("strip") || n.contains("лент") { return "strip" }
        if n.contains("floor") || n.contains("торшер") { return "floor" }
        if ["desk", "table", "bedside", "night", "насто", "ночн"].contains(where: n.contains) { return "table" }
        if n.contains("pendant") || n.contains("люстр") { return "pendant" }
        if n.contains("spot") { return "spots" }
        return "ceiling"
    }

    /// Adds real devices (as `DeviceHub.allDevices` lists them) to `room` as linked lamps
    /// and ACs, spread over the room so none stands on another. Sensors are skipped.
    /// Returns the ids of the new items.
    @discardableResult
    public mutating func add(_ devices: [[String: Any]], to room: String) -> [String] {
        guard let r = rect(of: room) else { return [] }
        let (x, z, w, d) = (r[0], r[1], r[2], r[3])
        var taken = allIds
        var lights = plan["lights"] as? [[String: Any]] ?? []
        var acs = plan["acs"] as? [[String: Any]] ?? []
        let newLights = devices.filter { ($0["kind"] as? String) == "light" }
        let newACs = devices.filter { ($0["kind"] as? String) == "ac" }
        var added: [String] = []

        // Lamps on a grid inside the room, away from the lamps already there.
        let existing = lights.filter { $0["room"] as? String == room }.count
        let total = existing + newLights.count
        let columns = max(1, Int(Double(total).squareRoot().rounded(.up)))
        let rows = max(1, Int((Double(total) / Double(columns)).rounded(.up)))
        for (n, device) in newLights.enumerated() {
            let slot = existing + n
            let cx = x + w * (Double(slot % columns) + 0.5) / Double(columns)
            let cz = z + d * (Double(slot / columns) + 0.5) / Double(rows)
            let name = device["name"] as? String ?? "Light"
            let id = uniqueId("\(room).light", taken: taken)
            taken.insert(id)
            var light: [String: Any] = ["id": id, "name": name, "room": room, "type": Self.fixture(for: name),
                                        "pos": [Self.fix(cx), Self.fix(cz)],
                                        "capabilities": device["capabilities"] as? [String] ?? []]
            if light["type"] as? String == "strip" { light["length"] = 1.0 }
            lights.append(light)
            added.append(id)
        }

        // ACs along the north wall, then the others, spaced out.
        let walls = ["north", "south", "west", "east"]
        let existingACs = acs.filter { $0["room"] as? String == room }.count
        for (n, device) in newACs.enumerated() {
            let slot = existingACs + n
            let wall = walls[slot % 4]
            let along = Double(slot / 4 + 1) / Double(slot / 4 + 2)
            let pos: [Double]
            switch wall {
            case "north": pos = [x + w * along, z]
            case "south": pos = [x + w * along, z + d]
            case "west": pos = [x, z + d * along]
            default: pos = [x + w, z + d * along]
            }
            let id = uniqueId("\(room).ac", taken: taken)
            taken.insert(id)
            var ac: [String: Any] = ["id": id, "name": device["name"] as? String ?? "AC", "room": room, "wall": wall,
                                     "pos": pos.map(Self.fix), "y": 2.2]
            if let min = (device["min"] as? NSNumber)?.doubleValue, let max = (device["max"] as? NSNumber)?.doubleValue {
                ac["min"] = Int(min.rounded())
                ac["max"] = Int(max.rounded())
            }
            acs.append(ac)
            added.append(id)
        }
        plan["lights"] = lights
        plan["acs"] = acs
        // Link each new item to its device.
        for (id, device) in zip(added, newLights + newACs) { link(id, to: device) }
        return added
    }

    /// Removes a lamp or an AC, and its mentions in the scenes.
    public mutating func remove(_ id: String) {
        guard let (key, i) = index(of: id), var list = plan[key] as? [[String: Any]] else { return }
        list.remove(at: i)
        plan[key] = list
        guard var scenes = plan["scenes"] as? [[String: Any]] else { return }
        for s in scenes.indices {
            for map in ["lights", "acs"] {
                if var rules = scenes[s][map] as? [String: Any] {
                    rules[id] = nil
                    scenes[s][map] = rules
                }
            }
        }
        plan["scenes"] = scenes
    }

    /// Adds a room east of the others; returns its id.
    @discardableResult
    public mutating func addRoom(named name: String, width: Double = 4, depth: Double = 3.5) -> String {
        var rooms = plan["rooms"] as? [[String: Any]] ?? []
        let rects = rooms.compactMap { ($0["rect"] as? [NSNumber])?.map(\.doubleValue) }.filter { $0.count == 4 }
        let maxX = rects.map { $0[0] + $0[2] }.max() ?? 0
        let minZ = rects.map { $0[1] }.min() ?? 0
        let base = Self.slug(name)
        let id = uniqueId(base, taken: allIds)
        rooms.append(["id": id, "name": name, "rect": [Self.fix(maxX), Self.fix(minZ), width, depth], "floor": "oak"])
        plan["rooms"] = rooms
        return id
    }

    static func slug(_ text: String) -> String {
        let s = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
        let trimmed = s.split(separator: "-").joined(separator: "-")
        return trimmed.isEmpty ? "room" : trimmed
    }

    // MARK: - New home

    /// A new home with one room, ready to be drawn further: the starting point of a home set
    /// up on the phone.
    public static func blank(name: String) -> [String: Any] {
        [
            "version": 1,
            "name": name,
            "wallHeight": 2.6,
            "interiorWallHeight": 1.25,
            "camera": ["azimuth": 34, "elevation": 47],
            "rooms": [["id": "living", "name": "Living room", "rect": [0.0, 0.0, 5.0, 4.0], "floor": "oak"]],
            "openings": [[String: Any]](),
            "furniture": [[String: Any]](),
            "lights": [[String: Any]](),
            "acs": [[String: Any]](),
            "scenes": [
                ["id": "bright", "name": "Bright", "icon": "sun", "lights": ["*": ["on": true, "brightness": 1]]],
                ["id": "off", "name": "All off", "icon": "moon", "lights": ["*": ["on": false]], "acs": ["*": ["on": false]]],
            ],
        ]
    }
}
