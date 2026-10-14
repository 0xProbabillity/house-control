import Foundation

/// Translates between HomeKit characteristics and the panel's vocabulary. Kept apart from
/// HomeKit itself (which only exists on iOS) so it can be tested anywhere. Values are keyed
/// by short names: "on", "brightness", "colorTemperature", "hue", "saturation", "active",
/// "targetState", "coolingThreshold", "heatingThreshold", "rotationSpeed", "swing",
/// "currentTemperature", "targetTemperature".
public enum HomeKitMapper {
    public enum Kind: String {
        case light, outlet, heaterCooler, thermostat, sensor

        public var device: DeviceKind {
            switch self {
            case .light, .outlet: return .light
            case .heaterCooler, .thermostat: return .ac
            case .sensor: return .sensor
            }
        }
    }

    /// HomeKit's service and characteristic type UUIDs, as HMServiceType… / HMCharacteristicType… hold them.
    public static let serviceKinds: [String: Kind] = [
        "00000043-0000-1000-8000-0026BB765291": .light,        // Lightbulb
        "00000047-0000-1000-8000-0026BB765291": .outlet,       // Outlet
        "00000049-0000-1000-8000-0026BB765291": .outlet,       // Switch
        "000000BC-0000-1000-8000-0026BB765291": .heaterCooler, // Heater Cooler (most ACs)
        "0000004A-0000-1000-8000-0026BB765291": .thermostat,   // Thermostat
        "0000008A-0000-1000-8000-0026BB765291": .sensor,       // Temperature Sensor
    ]

    public static let characteristicNames: [String: String] = [
        "00000025-0000-1000-8000-0026BB765291": "on",
        "00000008-0000-1000-8000-0026BB765291": "brightness",
        "000000CE-0000-1000-8000-0026BB765291": "colorTemperature",
        "00000013-0000-1000-8000-0026BB765291": "hue",
        "0000002F-0000-1000-8000-0026BB765291": "saturation",
        "000000B0-0000-1000-8000-0026BB765291": "active",
        "000000B2-0000-1000-8000-0026BB765291": "targetState",        // heater cooler: 0 auto, 1 heat, 2 cool
        "00000033-0000-1000-8000-0026BB765291": "targetHeatingCooling", // thermostat: 0 off, 1 heat, 2 cool, 3 auto
        "0000000D-0000-1000-8000-0026BB765291": "coolingThreshold",
        "00000012-0000-1000-8000-0026BB765291": "heatingThreshold",
        "00000029-0000-1000-8000-0026BB765291": "rotationSpeed",
        "000000B6-0000-1000-8000-0026BB765291": "swing",
        "00000011-0000-1000-8000-0026BB765291": "currentTemperature",
        "00000035-0000-1000-8000-0026BB765291": "targetTemperature",
    ]

    public static func kind(ofService type: String) -> Kind? { serviceKinds[type.uppercased()] }
    public static func name(ofCharacteristic type: String) -> String? { characteristicNames[type.uppercased()] }

    // MARK: - Lights

    public static func capabilities(_ names: Set<String>) -> [String] {
        var caps: [String] = []
        if names.contains("brightness") { caps.append("brightness") }
        if names.contains("colorTemperature") { caps.append("temp") }
        if names.contains("hue") && names.contains("saturation") { caps.append("color") }
        return caps
    }

    /// `whiteMode`: the lamp was last set to a white temperature (HomeKit does not say which
    /// of its colour and white settings is the one in effect).
    public static func lightState(_ v: [String: Any], whiteMode: Bool? = nil) -> [String: Any] {
        var out: [String: Any] = [:]
        if let on = v["on"] as? Bool ?? (v.double("on").map { $0 != 0 }) { out["on"] = on }
        if let b = v.double("brightness") { out["brightness"] = max(0.05, min(1, b / 100)) }
        let hasWhite = v.double("colorTemperature") != nil
        let hasColour = v.double("hue") != nil && v.double("saturation") != nil
        let white = whiteMode ?? (hasWhite && (!hasColour || (v.double("saturation") ?? 0) < 15))
        if white, let mired = v.double("colorTemperature") {
            out["temp"] = max(2200, min(6500, ColorMath.kelvin(mired: mired).rounded()))
            out["color"] = NSNull()
        } else if hasColour, let h = v.double("hue"), let s = v.double("saturation") {
            out["color"] = ColorMath.hex(hue: h, saturation: s / 100)
        }
        return out
    }

    /// The characteristic writes for a change to a lamp, in order. `limits` holds each
    /// characteristic's (min, max) where HomeKit reported them.
    public static func lightWrites(_ patch: [String: Any], kind: Kind, has: Set<String>,
                                   limits: [String: (Double, Double)] = [:]) -> [(String, Any)] {
        var out: [(String, Any)] = []
        func clamp(_ name: String, _ value: Double) -> Double {
            guard let (lo, hi) = limits[name] else { return value }
            return max(lo, min(hi, value))
        }
        if let on = patch["on"] as? Bool { out.append(("on", on)) }
        guard kind == .light else { return out }
        if let b = patch["brightness"] as? Double, has.contains("brightness") {
            out.append(("brightness", Int(clamp("brightness", (b * 100).rounded()))))
        }
        if let k = patch["temp"] as? Double, has.contains("colorTemperature") {
            out.append(("colorTemperature", Int(clamp("colorTemperature", ColorMath.mired(kelvin: k).rounded()))))
        }
        if let hex = patch["color"] as? String, has.contains("hue"), let (h, s, _) = ColorMath.hsv(hex) {
            out.append(("hue", (h * 10).rounded() / 10))
            out.append(("saturation", (s * 1000).rounded() / 10))
        }
        return out
    }

    // MARK: - Air conditioners

    static let heaterCoolerModes: [Int: String] = [0: "auto", 1: "heat", 2: "cool"]
    static let thermostatModes: [Int: String] = [1: "heat", 2: "cool", 3: "auto"]

    public static func acState(_ v: [String: Any], kind: Kind) -> [String: Any] {
        var out: [String: Any] = [:]
        if let room = v.double("currentTemperature") { out["roomTemp"] = (room * 10).rounded() / 10 }
        if kind == .thermostat {
            let mode = Int(v.double("targetHeatingCooling") ?? 0)
            out["on"] = mode != 0
            if let m = thermostatModes[mode] { out["mode"] = m }
            if let t = v.double("targetTemperature") { out["target"] = t.rounded() }
            return out
        }
        if let active = v.double("active") ?? (v["active"] as? Bool).map({ $0 ? 1 : 0 }) { out["on"] = active == 1 }
        let mode = heaterCoolerModes[Int(v.double("targetState") ?? 2)] ?? "cool"
        out["mode"] = mode
        let cool = v.double("coolingThreshold"), heat = v.double("heatingThreshold")
        switch mode {
        case "heat": if let t = heat ?? cool { out["target"] = t.rounded() }
        case "auto":
            if let c = cool, let h = heat { out["target"] = ((c + h) / 2).rounded() } else if let t = cool ?? heat { out["target"] = t.rounded() }
        default: if let t = cool ?? heat { out["target"] = t.rounded() }
        }
        if let speed = v.double("rotationSpeed") { out["fan"] = speed <= 34 ? "low" : speed <= 67 ? "medium" : "high" }
        if let swing = v.double("swing") { out["swing"] = swing == 1 ? "swing" : "off" }
        return out
    }

    /// `validModes`: the target-state values the accessory accepts, when it says.
    public static func acFeatures(kind: Kind, has: Set<String>, validModes: [Int]? = nil) -> [String: Any] {
        let table = kind == .thermostat ? thermostatModes : heaterCoolerModes
        let accepted = validModes.map(Set.init) ?? Set(table.keys)
        let modes = ["cool", "heat", "auto"].filter { m in table.contains { $0.value == m && accepted.contains($0.key) } }
        return [
            "modes": modes,
            "fans": has.contains("rotationSpeed") ? ["low", "medium", "high"] : [],
            "swing": has.contains("swing"), "sleep": false, "eco": false,
        ]
    }

    public static func acWrites(_ patch: [String: Any], state: [String: Any], kind: Kind, has: Set<String>,
                                limits: [String: (Double, Double)] = [:]) -> [(String, Any)] {
        var out: [(String, Any)] = []
        func clamp(_ name: String, _ value: Double) -> Double {
            guard let (lo, hi) = limits[name] else { return value }
            return max(lo, min(hi, value))
        }
        let mode = (patch["mode"] as? String) ?? (state["mode"] as? String) ?? "cool"
        if kind == .thermostat {
            if patch["on"] as? Bool == false { return [("targetHeatingCooling", 0)] }
            if patch["on"] as? Bool == true || patch["mode"] != nil,
               let value = thermostatModes.first(where: { $0.value == mode })?.key {
                out.append(("targetHeatingCooling", value))
            }
            if let t = patch["target"] as? Double { out.append(("targetTemperature", clamp("targetTemperature", t))) }
            return out
        }
        if let on = patch["on"] as? Bool { out.append(("active", on ? 1 : 0)) }
        if patch["mode"] != nil, let value = heaterCoolerModes.first(where: { $0.value == mode })?.key {
            out.append(("targetState", value))
        }
        if let t = (patch["target"] as? Double) ?? (patch["mode"] != nil ? state["target"] as? Double : nil) {
            switch mode {
            case "heat": out.append(("heatingThreshold", clamp("heatingThreshold", t)))
            case "auto":
                if has.contains("heatingThreshold") { out.append(("heatingThreshold", clamp("heatingThreshold", t - 1))) }
                if has.contains("coolingThreshold") { out.append(("coolingThreshold", clamp("coolingThreshold", t + 1))) }
            default: out.append(("coolingThreshold", clamp("coolingThreshold", t)))
            }
        }
        if let fan = patch["fan"] as? String, has.contains("rotationSpeed") {
            let speed: Double = ["low": 33, "medium": 66, "high": 100, "turbo": 100][fan] ?? 66
            out.append(("rotationSpeed", clamp("rotationSpeed", speed)))
        }
        if let swing = patch["swing"] as? String, has.contains("swing") { out.append(("swing", swing == "off" ? 0 : 1)) }
        return out
    }
}
