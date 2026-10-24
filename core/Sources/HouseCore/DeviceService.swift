import Foundation

/// A smart home platform the plan's lamps, ACs and blinds can be linked to, besides Smart Life:
/// Home Assistant, Philips Hue, Apple Home. Each one speaks the panel's own vocabulary —
/// a light is `on` / `brightness` 0…1 / `temp` in kelvin / `color` "#rrggbb", an AC is
/// `on` / `target` / `mode` / `fan` / …, a blind is `position` 0…1 (1 is fully open) and
/// `stop` — so the hub and the UI never see what is underneath.
@MainActor
public protocol DeviceService: AnyObject {
    /// "homeassistant", "hue", "homekit": what a plan's `link.service` says.
    var id: String { get }
    var title: String { get }
    var isConnected: Bool { get }
    /// What the editor may show about the connection. Never a token or key.
    var info: [String: Any] { get }
    /// Called when the platform says something changed (a lamp switched from its own app),
    /// so the hub can read the linked devices again without waiting for the next poll.
    var onChange: (() -> Void)? { get set }

    /// Every device the platform offers, as `ServiceDevice.dictionary`.
    func devices() async throws -> [ServiceDevice]
    /// The current state of the given devices. Devices the platform does not know are left out.
    func read(_ ids: Set<String>) async throws -> [String: DeviceReading]
    /// Applies a change made in the panel. `state` is the whole new state, for platforms
    /// that need more than the changed fields (a colour needs the brightness too).
    func send(kind: DeviceKind, id: String, patch: [String: Any], state: [String: Any]) async throws
    /// The devices linked in the plan, whose changes should reach `onChange`.
    func watch(_ ids: Set<String>)
    /// False for a catalog this device cannot act on (Apple Home on the Mac).
    var controlsDevices: Bool { get }
    /// Forgets the connection and its credentials.
    func disconnect()
}

public extension DeviceService {
    func watch(_ ids: Set<String>) {}
    var controlsDevices: Bool { true }
}

public enum DeviceKind: String {
    case light, ac, sensor, blind

    /// A lamp the panel shows as on, given a new brightness or colour, is switched on as well:
    /// the real one may be off (switched off elsewhere since the last read), and some
    /// platforms ignore a colour sent to a lamp that is off.
    static func withPower(_ patch: [String: Any], state: [String: Any]) -> [String: Any] {
        guard patch["on"] == nil, state["on"] as? Bool == true,
              ["brightness", "temp", "color"].contains(where: { patch[$0] != nil }) else { return patch }
        return patch.merging(["on": true]) { a, _ in a }
    }
}

/// One device as the editor lists it.
public struct ServiceDevice {
    public var id: String
    public var name: String
    public var kind: DeviceKind
    public var room: String?
    public var online = true
    /// For lights: which of "brightness", "temp", "color" it supports. For blinds: "position"
    /// when it can stop part-way, "stop" when it can be stopped while moving.
    public var capabilities: [String] = []
    /// For ACs: the set-point range it accepts.
    public var range: (min: Double, max: Double)?
    /// A short technical description ("light · color_temp, hs").
    public var detail = ""

    public init(id: String, name: String, kind: DeviceKind, room: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.room = room
    }

    public func dictionary(service: String) -> [String: Any] {
        var out: [String: Any] = ["service": service, "id": id, "name": name, "kind": kind.rawValue,
                                  "online": online, "capabilities": capabilities, "detail": detail]
        if let room { out["room"] = room }
        if let range { out["min"] = range.min; out["max"] = range.max }
        return out
    }
}

/// What one device reports, in the panel's terms.
public struct DeviceReading {
    public var light: [String: Any]?
    public var ac: [String: Any]?
    /// A blind's `position` 0…1 and, while it travels, `moving`: "opening" or "closing".
    public var blind: [String: Any]?
    /// What an AC can do: `modes`, `fans`, `swing`, `sleep`, `eco` (see the store's acFeatures).
    public var features: [String: Any]?
    /// A temperature sensor's reading in °C.
    public var temperature: Double?
    public var online = true

    public init(light: [String: Any]? = nil, ac: [String: Any]? = nil, blind: [String: Any]? = nil,
                features: [String: Any]? = nil, temperature: Double? = nil, online: Bool = true) {
        self.light = light
        self.ac = ac
        self.blind = blind
        self.features = features
        self.temperature = temperature
        self.online = online
    }
}

public struct ServiceFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Colour

/// Conversions between the panel's "#rrggbb" and what the platforms take.
public enum ColorMath {
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func hex(r: Double, g: Double, b: Double) -> String {
        func byte(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// Hue in degrees 0…360, saturation and value 0…1.
    public static func hsv(_ hex: String) -> (h: Double, s: Double, v: Double)? {
        guard let (r, g, b) = rgb(hex) else { return nil }
        let hi = max(r, g, b), lo = min(r, g, b), d = hi - lo
        var h = 0.0
        if d > 0 {
            if hi == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if hi == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, hi == 0 ? 0 : d / hi, hi)
    }

    /// The colour of a hue and saturation at full value, as the panel shows it.
    public static func hex(hue: Double, saturation: Double) -> String {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = max(0, min(1, saturation))
        let c = s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = 1 - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return hex(r: r + m, g: g + m, b: b + m)
    }

    /// CIE 1931 xy of an sRGB colour (Philips' "wide gamut" conversion).
    public static func xy(_ hex: String) -> (x: Double, y: Double)? {
        guard let (r, g, b) = rgb(hex) else { return nil }
        func linear(_ c: Double) -> Double { c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92 }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let X = lr * 0.4124 + lg * 0.3576 + lb * 0.1805
        let Y = lr * 0.2126 + lg * 0.7152 + lb * 0.0722
        let Z = lr * 0.0193 + lg * 0.1192 + lb * 0.9505
        let sum = X + Y + Z
        guard sum > 0 else { return (0.3127, 0.3290) } // black: the white point
        return ((X / sum * 10000).rounded() / 10000, (Y / sum * 10000).rounded() / 10000)
    }

    /// The sRGB colour of an xy chromaticity at full brightness.
    public static func hex(x: Double, y: Double) -> String {
        guard y > 0 else { return "#ffffff" }
        let Y = 1.0, X = Y / y * x, Z = Y / y * (1 - x - y)
        var r = X * 3.2406 - Y * 1.5372 - Z * 0.4986
        var g = -X * 0.9689 + Y * 1.8758 + Z * 0.0415
        var b = X * 0.0557 - Y * 0.2040 + Z * 1.0570
        let top = max(r, g, b, 1e-9)
        (r, g, b) = (max(0, r / top), max(0, g / top), max(0, b / top))
        func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        return hex(r: gamma(r), g: gamma(g), b: gamma(b))
    }

    /// Kelvin ↔ mired (what Hue and HomeKit use for white temperature).
    public static func mired(kelvin: Double) -> Double { 1_000_000 / max(1000, kelvin) }
    public static func kelvin(mired: Double) -> Double { 1_000_000 / max(1, mired) }
}

// MARK: - Air conditioner vocabulary

/// Maps whatever a platform calls its fan speeds onto the panel's five.
enum FanNames {
    static func panel(_ name: String) -> String? {
        let n = name.lowercased()
        if ["turbo", "max", "strong", "highest", "powerful", "boost", "very high"].contains(where: n.contains) { return "turbo" }
        if n.contains("high") { return "high" }
        if n.contains("med") || n.contains("mid") { return "medium" }
        if n.contains("low") || n.contains("quiet") || n.contains("silent") { return "low" }
        if n.contains("auto") { return "auto" }
        return nil
    }

    /// For each panel fan speed, the platform's own name for it (the first one that maps).
    static func table(_ names: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for name in names where name.lowercased() != "off" {
            if let p = panel(name), out[p] == nil { out[p] = name }
        }
        return out
    }

    static let order = ["auto", "low", "medium", "high", "turbo"]
}

extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double? {
        if let v = self[key] as? Double { return v }
        if let v = self[key] as? Int { return Double(v) }
        if let v = self[key] as? NSNumber { return v.doubleValue }
        if let v = self[key] as? String { return Double(v) }
        return nil
    }
}
