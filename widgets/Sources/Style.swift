import SwiftUI
import WidgetKit
import HouseCore

/// The panel's palette (web/src/style.css), so a widget reads as the same app.
enum Palette {
    static let night = Color(hex: "#0a0e1a")
    static let dusk = Color(hex: "#161d33")
    static let text = Color(hex: "#f3f5fa")
    static let muted = Color(hex: "#dee6f7").opacity(0.6)
    static let faint = Color(hex: "#dee6f7").opacity(0.36)
    static let glass = Color.white.opacity(0.07)
    static let glassHigh = Color.white.opacity(0.12)
    static let line = Color.white.opacity(0.09)
    static let accent = Color(hex: "#3d8bff")
    static let warm = Color(hex: "#ffb46b")
    static let cool = Color(hex: "#56c2ff")
    static let heat = Color(hex: "#ff8a4c")
    static let green = Color(hex: "#4ade80")
}

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0xffffff
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }

    /// The colour of white light at `kelvin` (Tanner Helland's fit), as warm as the 3D view draws it.
    init(kelvin: Double) {
        let t = max(1000, min(40000, kelvin)) / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func c(_ v: Double) -> Double { max(0, min(255, v)) / 255 }
        self.init(red: c(r), green: c(g), blue: c(b))
    }
}

extension HomeSnapshot.Light {
    /// What the lamp shines in: its colour, or its white temperature (plugs glow warm).
    var glow: Color {
        if let color { return Color(hex: color) }
        return capabilities.contains("temp") ? Color(kelvin: temp) : Palette.warm
    }

    var level: Double { capabilities.contains("brightness") ? brightness : 1 }

    var stateText: String {
        guard on else { return "Off" }
        return capabilities.contains("brightness") ? "\(Int((brightness * 100).rounded()))%" : "On"
    }
}

extension HomeSnapshot.AC {
    var modeSymbol: String {
        switch mode {
        case "heat": return "flame.fill"
        case "dry": return "drop.fill"
        case "fan": return "fan.fill"
        case "auto": return "arrow.triangle.2.circlepath"
        default: return "snowflake"
        }
    }

    var modeName: String { mode.prefix(1).uppercased() + mode.dropFirst() }

    var tint: Color {
        guard on else { return Palette.muted }
        switch mode {
        case "heat": return Palette.heat
        case "fan", "dry": return Color(hex: "#7dd3c0")
        case "auto": return Color(hex: "#a78bfa")
        default: return Palette.cool
        }
    }

    var targetText: String { "\(Int(target))°" }
    var roomText: String? { roomTemp.map { String(format: "%.1f°", $0) } }
}

extension HomeSnapshot.Scene {
    /// A colour that says what the scene does: its brightest colour, else warm or cool white.
    var tint: Color {
        let patches = lights.values
        if let hex = patches.compactMap({ $0["color"]?.string }).first { return Color(hex: hex) }
        let anyOn = patches.contains { $0["on"]?.bool == true }
        if !anyOn { return Color(hex: "#8b9cff") }
        if let t = patches.compactMap({ $0["temp"]?.number }).max() { return t >= 4000 ? Color(hex: "#ffe3a8") : Palette.warm }
        return Palette.warm
    }
}

extension HomeSnapshot {
    /// "6 of 11 lights on", "All lights off".
    var lightsLine: String {
        lightsOn == 0 ? "All lights off" : "\(lightsOn) of \(lights.count) \(lights.count == 1 ? "light" : "lights") on"
    }

    var climateLine: String? {
        guard let ac = acsOn.first else { return nil }
        return "\(ac.modeName) \(ac.targetText)"
    }

    var activeScene: Scene? { scenes.first { $0.id == scene } }

    /// Rooms with lamps, in plan order.
    var roomsWithLights: [Room] { rooms.filter { r in lights.contains { $0.room == r.id } } }

    /// Just one room, with its lamps, ACs and furniture: for a model of that room alone.
    func only(_ id: String) -> HomeSnapshot {
        guard let room = room(id) else { return self }
        var copy = self
        copy.rooms = [room]
        copy.lights = lights.filter { $0.room == id }
        copy.acs = acs.filter { $0.room == id }
        copy.furniture = furniture?.filter { $0.x >= room.x && $0.x <= room.x + room.w && $0.z >= room.z && $0.z <= room.z + room.d }
        return copy
    }
}

/// The night-blue background every widget sits on, with a warm bloom when lamps are on.
struct WidgetBackdrop: View {
    var warmth: Double = 0

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.dusk, Palette.night], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.warm.opacity(0.18 * warmth), .clear], center: .init(x: 0.5, y: 0.42),
                           startRadius: 0, endRadius: 220)
        }
    }
}

extension View {
    /// The widget's background, which the system removes in StandBy or the tinted home screen.
    func homeBackground(warmth: Double = 0) -> some View {
        containerBackground(for: .widget) { WidgetBackdrop(warmth: warmth) }
    }
}

/// A small caps label above a group ("SCENES", "LIVING").
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .kerning(0.9)
            .foregroundStyle(Palette.faint)
            .lineLimit(1)
    }
}

/// The deep links the app understands.
enum DeepLink {
    static func home() -> URL { URL(string: "housecontrol://open")! }
    static func device(_ id: String) -> URL {
        var c = URLComponents()
        c.scheme = "housecontrol"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "device", value: id)]
        return c.url!
    }
}

// MARK: - Family and rendering mode

private struct StillFamilyKey: EnvironmentKey { static let defaultValue: WidgetFamily? = nil }
private struct StillModeKey: EnvironmentKey { static let defaultValue: WidgetRenderingMode? = nil }

extension EnvironmentValues {
    /// Set by `widgets/Render`, which draws the widgets as still images outside WidgetKit
    /// (the system's own values cannot be set there).
    var stillFamily: WidgetFamily? {
        get { self[StillFamilyKey.self] }
        set { self[StillFamilyKey.self] = newValue }
    }

    var stillRenderingMode: WidgetRenderingMode? {
        get { self[StillModeKey.self] }
        set { self[StillModeKey.self] = newValue }
    }
}

/// The family a widget is drawn for and whether it is in full colour (not the tinted or
/// clear home screen, StandBy at night, or the Lock Screen).
struct WidgetLook: DynamicProperty {
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    @Environment(\.stillFamily) private var stillFamily
    @Environment(\.stillRenderingMode) private var stillRenderingMode

    var family: WidgetFamily { stillFamily ?? widgetFamily }

    enum Accessory { case circular, rectangular, inline }

    /// Which Lock Screen shape this is (accessory families exist on the iPhone only).
    var accessory: Accessory? {
        #if os(iOS)
        switch family {
        case .accessoryCircular: return .circular
        case .accessoryRectangular: return .rectangular
        case .accessoryInline: return .inline
        default: return nil
        }
        #else
        return nil
        #endif
    }
    var fullColor: Bool { (stillRenderingMode ?? widgetRenderingMode) == .fullColor }
}
