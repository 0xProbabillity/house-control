import Foundation

/// What the widgets and controls know about the home: the plan's rooms, lamps, ACs and
/// scenes with the state each device was last in. The panel page writes it
/// (`web/src/widgets.js`) whenever something changes; a widget that changes something
/// applies the change here first, so it can show the result at once.
public struct HomeSnapshot: Codable, Equatable, Sendable {
    public struct Room: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// The room's rectangle on the floor plan, in metres.
        public var x: Double, z: Double, w: Double, d: Double
        public var floor: String?
    }

    public struct Light: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var room: String
        /// "ceiling", "pendant", "spots", "floor", "table" or "strip".
        public var type: String
        public var x: Double, z: Double
        /// Which of "brightness", "temp", "color" it supports.
        public var capabilities: [String]
        public var on: Bool
        public var brightness: Double
        /// White temperature in kelvin.
        public var temp: Double
        /// "#rrggbb" while it shows a colour instead of white.
        public var color: String?
        /// The platform it is linked to ("smartlife", "homeassistant", "hue", "homekit"); nil when simulated.
        public var service: String?
        /// The plan's `tuya` / `link` / `sensor` fields, for sending commands from a widget.
        public var links: [String: JSONValue]?
    }

    public struct AC: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var room: String
        public var wall: String
        public var x: Double, z: Double
        public var min: Double, max: Double
        public var on: Bool
        public var target: Double
        public var mode: String
        public var fan: String
        public var roomTemp: Double?
        public var swing: String?
        public var sleep: Bool?
        public var eco: Bool?
        public var service: String?
        public var links: [String: JSONValue]?
    }

    public struct Scene: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// The panel's icon name: "sun", "sofa", "film", "moon", "door", "table"…
        public var icon: String
        /// Device id (or "*" for every device) -> the fields the scene sets.
        public var lights: [String: [String: JSONValue]]
        public var acs: [String: [String: JSONValue]]
    }

    /// A piece of furniture: its footprint on the plan (`w` × `d` metres, turned by `rot` degrees).
    public struct Furniture: Codable, Equatable, Sendable {
        public var type: String
        public var x: Double, z: Double, w: Double, d: Double
        public var rot: Double
        public var color: String?
    }

    public var version = 1
    public var name: String
    /// "home" / "studio" for the bundled demos, "custom" for the user's own plan.
    public var plan: String
    public var outdoorTemp: Double?
    public var rooms: [Room]
    public var lights: [Light]
    public var acs: [AC]
    public var furniture: [Furniture]?
    public var scenes: [Scene]
    /// The scene the home is in, until something is changed by hand.
    public var scene: String?
    /// When the state was last written, in seconds since 1970.
    public var updated: Double

    public init(name: String, plan: String, outdoorTemp: Double? = nil, rooms: [Room], lights: [Light], acs: [AC],
                scenes: [Scene], scene: String? = nil, updated: Double = Date().timeIntervalSince1970) {
        self.name = name
        self.plan = plan
        self.outdoorTemp = outdoorTemp
        self.rooms = rooms
        self.lights = lights
        self.acs = acs
        self.scenes = scenes
        self.scene = scene
        self.updated = updated
    }

    public var lightsOn: Int { lights.filter(\.on).count }
    /// Tells homes apart: the plan and its name.
    public var identity: String { "\(plan):\(name)" }
    public var acsOn: [AC] { acs.filter(\.on) }
    /// True when no device is linked to a real one.
    public var isSimulated: Bool { lights.allSatisfy { $0.service == nil } && acs.allSatisfy { $0.service == nil } }

    public func room(_ id: String) -> Room? { rooms.first { $0.id == id } }
    public func light(_ id: String) -> Light? { lights.first { $0.id == id } }
    public func ac(_ id: String) -> AC? { acs.first { $0.id == id } }
    public func lights(in room: String) -> [Light] { lights.filter { $0.room == room } }

    /// The plan fragment `DeviceHub.setLinks` reads: each device with its links.
    public var linksPlan: [String: Any] {
        func entry(_ id: String, _ links: [String: JSONValue]?) -> [String: Any] {
            var out: [String: Any] = ["id": id]
            for (key, value) in links ?? [:] { out[key] = value.any }
            return out
        }
        return ["lights": lights.map { entry($0.id, $0.links) }, "acs": acs.map { entry($0.id, $0.links) }]
    }
}

/// Something a widget or a control asks the home to do. Stored with explicit values
/// (a toggle is resolved to on or off when it is made), so the app replays exactly what
/// the widget showed.
public struct HomeAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A lamp on or off.
        case light
        /// Every lamp of a room.
        case room
        /// Every lamp of the home.
        case allLights
        case scene
        case acPower
        /// An AC's set-point, in °C.
        case acTarget
    }

    public var kind: Kind
    public var id: String?
    /// For light, room, allLights and acPower; nil means "the other way round".
    public var on: Bool?
    public var target: Double?

    public init(_ kind: Kind, id: String? = nil, on: Bool? = nil, target: Double? = nil) {
        self.kind = kind
        self.id = id
        self.on = on
        self.target = target
    }

    public static func light(_ id: String, on: Bool? = nil) -> HomeAction { .init(.light, id: id, on: on) }
    public static func room(_ id: String, on: Bool? = nil) -> HomeAction { .init(.room, id: id, on: on) }
    public static func allLights(on: Bool) -> HomeAction { .init(.allLights, on: on) }
    public static func scene(_ id: String) -> HomeAction { .init(.scene, id: id) }
    public static func acPower(_ id: String, on: Bool? = nil) -> HomeAction { .init(.acPower, id: id, on: on) }
    public static func acTarget(_ id: String, _ target: Double) -> HomeAction { .init(.acTarget, id: id, target: target) }
}

/// A change one device has to make, as the hub's `command` takes it.
public struct DeviceChange: @unchecked Sendable {
    public var kind: DeviceKind
    public var id: String
    public var patch: [String: Any]
    /// The device's whole new state.
    public var state: [String: Any]

    public var message: [String: Any] { ["kind": kind.rawValue, "id": id, "patch": patch, "state": state] }
}

public extension HomeSnapshot {
    /// Applies `action` the way the panel's store does (`web/src/store.js`): the same
    /// clamping, the same scene rules. Returns the action with every toggle resolved and
    /// what each device has to change; a no-op returns no changes.
    mutating func apply(_ action: HomeAction) -> (resolved: HomeAction, changes: [DeviceChange]) {
        var resolved = action
        var changes: [DeviceChange] = []
        switch action.kind {
        case .light:
            guard let id = action.id, let light = light(id) else { break }
            let on = action.on ?? !light.on
            resolved.on = on
            if let change = writeLight(id, ["on": .bool(on)]) { changes.append(change); scene = nil }
        case .room:
            guard let id = action.id else { break }
            let inRoom = lights(in: id)
            let on = action.on ?? !inRoom.contains(where: \.on)
            resolved.on = on
            changes = inRoom.compactMap { writeLight($0.id, ["on": .bool(on)]) }
            if !changes.isEmpty { scene = nil }
        case .allLights:
            let on = action.on ?? (lightsOn == 0)
            resolved.on = on
            changes = lights.compactMap { writeLight($0.id, ["on": .bool(on)]) }
            if !changes.isEmpty { scene = nil }
        case .scene:
            guard let id = action.id, let definition = scenes.first(where: { $0.id == id }) else { break }
            for light in lights {
                var patch = (definition.lights["*"] ?? [:]).merging(definition.lights[light.id] ?? [:]) { $1 }
                // A scene that sets a white temperature should not be overridden by a stale colour.
                if patch["color"] == nil, patch["temp"] != nil { patch["color"] = .null }
                if let change = writeLight(light.id, patch) { changes.append(change) }
            }
            for ac in acs {
                let patch = (definition.acs["*"] ?? [:]).merging(definition.acs[ac.id] ?? [:]) { $1 }
                if !patch.isEmpty, let change = writeAC(ac.id, patch) { changes.append(change) }
            }
            scene = id
        case .acPower:
            guard let id = action.id, let ac = ac(id) else { break }
            let on = action.on ?? !ac.on
            resolved.on = on
            if let change = writeAC(id, ["on": .bool(on)]) { changes.append(change) }
        case .acTarget:
            guard let id = action.id, let target = action.target, let ac = ac(id) else { break }
            let clamped = Swift.min(ac.max, Swift.max(ac.min, target.rounded()))
            resolved.target = clamped
            if let change = writeAC(id, ["target": .number(clamped)]) { changes.append(change) }
        }
        if !changes.isEmpty { updated = Date().timeIntervalSince1970 }
        return (resolved, changes)
    }

    private mutating func writeLight(_ id: String, _ patch: [String: JSONValue]) -> DeviceChange? {
        guard let index = lights.firstIndex(where: { $0.id == id }) else { return nil }
        var light = lights[index]
        let caps = light.capabilities
        var diff: [String: Any] = [:]
        if let on = patch["on"]?.bool, on != light.on { light.on = on; diff["on"] = on }
        if caps.contains("brightness"), let b = patch["brightness"]?.number {
            let value = Swift.min(1, Swift.max(0.05, b))
            if value != light.brightness { light.brightness = value; diff["brightness"] = value }
        }
        if caps.contains("temp"), let t = patch["temp"]?.number {
            let value = Swift.min(6500, Swift.max(2200, t))
            if value != light.temp { light.temp = value; diff["temp"] = value }
            // Setting a white temperature drops the colour (store.js does the same).
            if light.color != nil { light.color = nil; diff["color"] = NSNull() }
        }
        if caps.contains("color"), let color = patch["color"] {
            let value = color.string
            if value != light.color { light.color = value; diff["color"] = value ?? NSNull() }
        }
        guard !diff.isEmpty else { return nil }
        lights[index] = light
        var state: [String: Any] = ["on": light.on, "brightness": light.brightness, "temp": light.temp]
        state["color"] = light.color ?? NSNull()
        return DeviceChange(kind: .light, id: id, patch: diff, state: state)
    }

    private mutating func writeAC(_ id: String, _ patch: [String: JSONValue]) -> DeviceChange? {
        guard let index = acs.firstIndex(where: { $0.id == id }) else { return nil }
        var ac = acs[index]
        var diff: [String: Any] = [:]
        if let on = patch["on"]?.bool, on != ac.on { ac.on = on; diff["on"] = on }
        if let t = patch["target"]?.number {
            let value = Swift.min(ac.max, Swift.max(ac.min, t.rounded()))
            if value != ac.target { ac.target = value; diff["target"] = value }
        }
        if let mode = patch["mode"]?.string, mode != ac.mode { ac.mode = mode; diff["mode"] = mode }
        if let fan = patch["fan"]?.string, fan != ac.fan { ac.fan = fan; diff["fan"] = fan }
        if let swing = patch["swing"]?.string, swing != ac.swing { ac.swing = swing; diff["swing"] = swing }
        if let sleep = patch["sleep"]?.bool, sleep != ac.sleep { ac.sleep = sleep; diff["sleep"] = sleep }
        if let eco = patch["eco"]?.bool, eco != ac.eco { ac.eco = eco; diff["eco"] = eco }
        guard !diff.isEmpty else { return nil }
        acs[index] = ac
        var state: [String: Any] = ["on": ac.on, "target": ac.target, "mode": ac.mode, "fan": ac.fan]
        if let swing = ac.swing { state["swing"] = swing }
        if let sleep = ac.sleep { state["sleep"] = sleep }
        if let eco = ac.eco { state["eco"] = eco }
        return DeviceChange(kind: .ac, id: id, patch: diff, state: state)
    }

    /// The state in the shape the panel's `adopt` takes.
    var panelState: [String: Any] {
        var lightsOut: [String: Any] = [:]
        for l in lights { lightsOut[l.id] = ["on": l.on, "brightness": l.brightness, "temp": l.temp, "color": (l.color as Any?) ?? NSNull()] }
        var acsOut: [String: Any] = [:]
        for a in acs {
            var s: [String: Any] = ["on": a.on, "target": a.target, "mode": a.mode, "fan": a.fan]
            if let v = a.swing { s["swing"] = v }
            if let v = a.sleep { s["sleep"] = v }
            if let v = a.eco { s["eco"] = v }
            acsOut[a.id] = s
        }
        return ["lights": lightsOut, "acs": acsOut, "scene": (scene as Any?) ?? NSNull(), "source": "Widget"]
    }
}

// SF Symbols for the widgets, the controls and the iPhone's quick actions.
public extension HomeSnapshot.Light {
    var symbol: String {
        switch type {
        case "ceiling": return "light.recessed.fill"
        case "pendant": return "light.cylindrical.ceiling.fill"
        case "spots": return "lightbulb.fill"
        case "floor": return "lamp.floor.fill"
        case "table": return "lamp.table.fill"
        case "strip": return "light.strip.2.fill"
        default: return "lightbulb.fill"
        }
    }

}

public extension HomeSnapshot.Scene {
    var symbol: String {
        switch icon {
        case "sun": return "sun.max.fill"
        case "sofa": return "sofa.fill"
        case "film": return "film.fill"
        case "moon": return "moon.stars.fill"
        case "door": return "door.left.hand.open"
        case "table": return "lamp.desk.fill"
        case "tv": return "tv.fill"
        case "bed": return "bed.double.fill"
        case "leaf": return "leaf.fill"
        case "power": return "power"
        default: return "sparkles"
        }
    }

}
