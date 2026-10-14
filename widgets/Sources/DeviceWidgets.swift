import SwiftUI
import WidgetKit
import AppIntents
import HouseCore

// MARK: - Scenes

/// One tap sets every lamp and AC: the home's scenes as big buttons.
struct ScenesWidget: Widget {
    static let kind = "scenes"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HomeProvider()) { entry in
            ScenesWidgetView(home: entry.home)
        }
        .configurationDisplayName("Scenes")
        .description("Cozy, Movie, Night… one tap sets every light and air conditioner.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ScenesWidgetView: View {
    let home: HomeSnapshot
    private let look = WidgetLook()
    private var family: WidgetFamily { look.family }

    var body: some View {
        let scenes = Array(home.scenes.prefix(4))
        VStack(alignment: .leading, spacing: 8) {
            if family == .systemMedium {
                HStack {
                    Caption("Scenes")
                    Spacer()
                    Text(home.activeScene?.name ?? home.lightsLine)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(home.activeScene == nil ? Palette.faint : Palette.text)
                }
                HStack(spacing: 8) {
                    ForEach(scenes) { SceneTile(scene: $0, active: $0.id == home.scene) }
                }
            } else {
                Grid(horizontalSpacing: 7, verticalSpacing: 7) {
                    GridRow {
                        ForEach(scenes.prefix(2)) { SceneTile(scene: $0, active: $0.id == home.scene, compact: true) }
                    }
                    GridRow {
                        ForEach(scenes.dropFirst(2).prefix(2)) { SceneTile(scene: $0, active: $0.id == home.scene, compact: true) }
                    }
                }
            }
        }
        .homeBackground()
        .widgetURL(DeepLink.home())
    }
}

// MARK: - One lamp

struct LightWidget: Widget {
    static let kind = "light"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: LightConfiguration.self, provider: ConfiguredProvider<LightConfiguration>()) { entry in
            LightWidgetView(entry: entry)
        }
        .configurationDisplayName("Light")
        .description("One lamp, glowing in its colour. Tap to switch it.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .accessoryCircular]
        #else
        [.systemSmall]
        #endif
    }
}

struct LightWidgetView: View {
    let entry: ConfiguredEntry<LightConfiguration>
    private let look = WidgetLook()
    private var family: WidgetFamily { look.family }

    var body: some View {
        let home = entry.home
        if let light = entry.configuration.light.flatMap({ home.light($0.id) }) ?? home.lights.first {
            if look.accessory == .circular {
                Button(intent: ToggleLightIntent(lightID: light.id)) {
                    ZStack {
                        AccessoryWidgetBackground()
                        Image(systemName: light.on ? "lightbulb.fill" : "lightbulb")
                            .font(.system(size: 22, weight: .semibold))
                            .widgetAccentable(light.on)
                    }
                }
                .buttonStyle(.plain)
                .containerBackground(for: .widget) { Color.clear }
                .accessibilityLabel("\(light.name), \(light.on ? "on" : "off")")
            } else {
                card(light, home)
            }
        } else {
            EmptyHome(text: "No lamps in this home yet")
        }
    }

    private func card(_ light: HomeSnapshot.Light, _ home: HomeSnapshot) -> some View {
        Button(intent: ToggleLightIntent(lightID: light.id)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    ZStack {
                        if light.on && look.fullColor {
                            Circle().fill(RadialGradient(colors: [light.glow.opacity(0.85), light.glow.opacity(0)],
                                                         center: .center, startRadius: 4, endRadius: 44))
                                .frame(width: 88, height: 88)
                        }
                        Image(systemName: light.symbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(light.on ? Color(hex: "#3a2208") : Palette.muted)
                            .frame(width: 50, height: 50)
                            .background(Circle().fill(light.on ? AnyShapeStyle(light.glow.gradient) : AnyShapeStyle(Palette.glassHigh)))
                            .widgetAccentable(light.on)
                    }
                    .frame(width: 50, height: 50)
                    Spacer()
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(light.on ? Palette.text : Palette.faint)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.glass))
                }
                Spacer(minLength: 4)
                Text(light.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(home.room(light.room)?.name ?? "")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                Text(light.stateText)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(light.on ? light.glow : Palette.muted)
                    .contentTransition(.numericText())
                    .widgetAccentable(light.on)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(light.name), \(light.on ? "on" : "off")")
        .containerBackground(for: .widget) {
            ZStack {
                WidgetBackdrop()
                if light.on {
                    RadialGradient(colors: [light.glow.opacity(0.32), .clear], center: .topLeading, startRadius: 0, endRadius: 190)
                }
            }
        }
        .widgetURL(DeepLink.device(light.id))
    }
}

// MARK: - A room's lamps

struct RoomWidget: Widget {
    static let kind = "room"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: RoomConfiguration.self, provider: ConfiguredProvider<RoomConfiguration>()) { entry in
            RoomWidgetView(entry: entry)
        }
        .configurationDisplayName("Room")
        .description("Every lamp of one room, each a tap away.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct RoomWidgetView: View {
    let entry: ConfiguredEntry<RoomConfiguration>
    private let look = WidgetLook()
    private var family: WidgetFamily { look.family }

    var body: some View {
        let home = entry.home
        if let room = entry.configuration.room.flatMap({ home.room($0.id) }) ?? home.roomsWithLights.first {
            let lights = home.lights(in: room.id)
            let on = lights.filter(\.on).count
            let capacity = family == .systemLarge ? 4 : 4
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                        Text(on == 0 ? "All off" : "\(on) of \(lights.count) on")
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(on == 0 ? Palette.faint : Palette.warm)
                    }
                    Spacer()
                    Button(intent: ToggleRoomIntent(roomID: room.id, on: on == 0)) {
                        Text(on == 0 ? "All on" : "All off")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.text)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(Palette.glassHigh))
                    }
                    .buttonStyle(.plain)
                }
                if family == .systemLarge {
                    // The room on its own, in 3D: its lamps glow in it and are buttons.
                    HouseModel(home: home.only(room.id), padding: 4, interactive: true, boost: 1.2)
                        .frame(maxHeight: .infinity)
                    if let ac = home.acs.first(where: { $0.room == room.id }) { RoomClimate(ac: ac) }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                    ForEach(lights.prefix(capacity)) { LightTile(light: $0).frame(height: 44) }
                }
                if family != .systemLarge { Spacer(minLength: 0) }
            }
            .homeBackground(warmth: min(1, Double(on) / 3))
            .widgetURL(DeepLink.device(room.id))
        } else {
            EmptyHome(text: "No room with lamps yet")
        }
    }
}

private struct RoomClimate: View {
    let ac: HomeSnapshot.AC

    var body: some View {
        HStack(spacing: 10) {
            ClimateDial(ac: ac, lineWidth: 5).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(ac.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text)
                Text(ac.on ? "\(ac.modeName) to \(ac.targetText)" : "Off")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(ac.on ? ac.tint : Palette.faint)
            }
            Spacer()
            ClimateButtons(ac: ac, size: 28)
        }
        .padding(8)
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Climate

struct ClimateWidget: Widget {
    static let kind = "climate"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: ClimateConfiguration.self, provider: ConfiguredProvider<ClimateConfiguration>()) { entry in
            ClimateWidgetView(entry: entry)
        }
        .configurationDisplayName("Climate")
        .description("An air conditioner's set-point and the room's temperature, with power and − / +.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

struct ClimateWidgetView: View {
    let entry: ConfiguredEntry<ClimateConfiguration>
    private let look = WidgetLook()
    private var family: WidgetFamily { look.family }

    var body: some View {
        let home = entry.home
        if let ac = entry.configuration.ac.flatMap({ home.ac($0.id) }) ?? home.acs.first {
            #if os(iOS)
            if look.accessory == .circular { circular(ac) } else if look.accessory == .rectangular { rectangular(ac, home) }
            else if family == .systemMedium { medium(ac, home) } else { small(ac) }
            #else
            if family == .systemMedium { medium(ac, home) } else { small(ac) }
            #endif
        } else {
            EmptyHome(text: "No air conditioner in this home")
        }
    }

    private func small(_ ac: HomeSnapshot.AC) -> some View {
        VStack(spacing: 6) {
            ZStack {
                ClimateDial(ac: ac, lineWidth: 8)
                VStack(spacing: -2) {
                    Image(systemName: ac.on ? ac.modeSymbol : "power")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ac.tint)
                        .widgetAccentable()
                    Text(ac.targetText)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(ac.on ? Palette.text : Palette.muted)
                        .contentTransition(.numericText(value: ac.target))
                    if let room = ac.roomText {
                        Text(room).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.faint)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            ClimateButtons(ac: ac, size: 30)
        }
        .homeBackground()
        .widgetURL(DeepLink.device(ac.id))
    }

    private func medium(_ ac: HomeSnapshot.AC, _ home: HomeSnapshot) -> some View {
        HStack(spacing: 14) {
            ZStack {
                ClimateDial(ac: ac, lineWidth: 9)
                VStack(spacing: -3) {
                    Text(ac.targetText)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(ac.on ? Palette.text : Palette.muted)
                        .contentTransition(.numericText(value: ac.target))
                    Text("target").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.faint)
                }
            }
            .frame(width: 118)
            VStack(alignment: .leading, spacing: 4) {
                Text(ac.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text(home.room(ac.room)?.name ?? "").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.faint)
                HStack(spacing: 6) {
                    chip(ac.on ? ac.modeName : "Off", ac.on ? ac.modeSymbol : "power", ac.tint)
                    if ac.on { chip("Fan \(ac.fan)", "fan", Palette.muted) }
                }
                .padding(.top, 2)
                if let room = ac.roomText {
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer.medium").font(.system(size: 11, weight: .semibold))
                        Text("Room \(room)").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 2)
                ClimateButtons(ac: ac, size: 32)
            }
        }
        .homeBackground()
        .widgetURL(DeepLink.device(ac.id))
    }

    private func chip(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Palette.glass))
            .widgetAccentable()
    }

    #if os(iOS)
    private func circular(_ ac: HomeSnapshot.AC) -> some View {
        Gauge(value: ac.roomTemp ?? ac.target, in: ac.min...ac.max) {
            Image(systemName: ac.on ? ac.modeSymbol : "air.conditioner.horizontal")
        } currentValueLabel: {
            Text(ac.roomTemp.map { "\(Int($0.rounded()))°" } ?? ac.targetText)
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        .widgetURL(DeepLink.device(ac.id))
    }

    private func rectangular(_ ac: HomeSnapshot.AC, _ home: HomeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(ac.name, systemImage: ac.on ? ac.modeSymbol : "air.conditioner.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .widgetAccentable()
            Text(ac.on ? "\(ac.modeName) to \(ac.targetText)" : "Off")
                .font(.system(size: 13, weight: .medium))
            if let room = ac.roomText { Text("Room \(room)").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(DeepLink.device(ac.id))
    }
    #endif
}

// MARK: - Lock Screen status

#if os(iOS)
/// The home at a glance on the Lock Screen: how many lamps are on, what the AC does.
struct StatusWidget: Widget {
    static let kind = "status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HomeProvider()) { entry in
            StatusWidgetView(home: entry.home)
        }
        .configurationDisplayName("Home Status")
        .description("Lamps on and the air conditioner, at a glance.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusWidgetView: View {
    let home: HomeSnapshot
    private let look = WidgetLook()
    private var family: WidgetFamily { look.family }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: Double(home.lightsOn), in: 0...Double(max(1, home.lights.count))) {
                    Image(systemName: "lightbulb.fill")
                } currentValueLabel: {
                    Text("\(home.lightsOn)")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
            case .accessoryInline:
                ViewThatFits {
                    Text(inline(long: true))
                    Text(inline(long: false))
                }
                .containerBackground(for: .widget) { Color.clear }
            default:
                VStack(alignment: .leading, spacing: 1) {
                    Label(home.name, systemImage: "house.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .widgetAccentable()
                    Text(home.lightsLine).font(.system(size: 13, weight: .medium))
                    if let ac = home.acsOn.first {
                        Text("\(ac.modeName) \(ac.targetText)\(ac.roomText.map { " · room \($0)" } ?? "")")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if let scene = home.activeScene {
                        Text("Scene: \(scene.name)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .containerBackground(for: .widget) { Color.clear }
            }
        }
        .widgetURL(DeepLink.home())
    }

    private func inline(long: Bool) -> String {
        var parts = [home.lightsOn == 0 ? "Lights off" : "\(home.lightsOn) \(long ? "lights " : "")on"]
        if let ac = home.acsOn.first { parts.append("\(ac.modeName) \(ac.targetText)") }
        return "⌂ " + parts.joined(separator: " · ")
    }
}
#endif

/// Shown when the home has nothing of the kind the widget is for.
struct EmptyHome: View {
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "house").font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.warm)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .homeBackground()
    }
}
