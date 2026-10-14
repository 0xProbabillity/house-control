import SwiftUI
import WidgetKit
import AppIntents
import HouseCore

/// The home as a live little model: every lamp glows on the floor of its room in its own
/// colour. Medium and larger add scenes; on large ones each lamp in the model is a button.
struct HomeWidget: Widget {
    static let kind = "home"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HomeProvider()) { entry in
            HomeWidgetView(entry: entry)
        }
        .configurationDisplayName("Home")
        .description("Your home in 3D, lit the way it is right now. Tap a lamp in the large sizes to switch it.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(macOS)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

struct HomeWidgetView: View {
    let entry: HomeEntry
    private let look = WidgetLook()
    private var family: WidgetFamily { look.family }

    var body: some View {
        let home = entry.home
        Group {
            switch family {
            case .systemSmall: small(home)
            case .systemMedium: medium(home)
            case .systemExtraLarge: extraLarge(home)
            default: large(home)
            }
        }
        .homeBackground(warmth: min(1, Double(home.lightsOn) / 4))
        .widgetURL(DeepLink.home())
    }

    private func small(_ home: HomeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HouseModel(home: home, padding: 0, boost: 1.6)
                .padding(.horizontal, -4)
                .frame(maxHeight: .infinity)
            HStack(alignment: .firstTextBaseline) {
                Text(home.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let ac = home.acsOn.first {
                    Label(ac.targetText, systemImage: ac.modeSymbol)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(ac.tint)
                        .widgetAccentable()
                }
            }
            LightsLine(home: home, size: 11)
        }
    }

    private func medium(_ home: HomeSnapshot) -> some View {
        HStack(spacing: 10) {
            HouseModel(home: home, padding: 0, boost: 1.25)
                .padding(.vertical, -6)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HomeTitle(home: home, size: 15)
                    Spacer(minLength: 4)
                    AllLightsButton(home: home, size: 28)
                }
                LightsLine(home: home)
                ClimateLine(home: home, size: 11)
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    ForEach(home.scenes.prefix(3)) { scene in
                        SceneTile(scene: scene, active: scene.id == home.scene, compact: true)
                    }
                }
                .frame(height: 50)
            }
            .frame(width: 168)
        }
    }

    private func large(_ home: HomeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HomeTitle(home: home, size: 16)
                    LightsLine(home: home, size: 12)
                }
                Spacer()
                AllLightsButton(home: home, size: 34)
            }
            HouseModel(home: home, padding: 6, interactive: true, boost: 1.1)
                .frame(maxHeight: .infinity)
            if let ac = home.acsOn.first ?? home.acs.first {
                climateStrip(ac)
            }
            HStack(spacing: 6) {
                ForEach(home.scenes.prefix(5)) { scene in
                    SceneTile(scene: scene, active: scene.id == home.scene, compact: true)
                }
            }
            .frame(height: 52)
        }
    }

    private func climateStrip(_ ac: HomeSnapshot.AC) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ac.on ? ac.modeSymbol : "air.conditioner.horizontal")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ac.on ? .white : Palette.muted)
                .frame(width: 28, height: 28)
                .background(Circle().fill(ac.on ? AnyShapeStyle(ac.tint.gradient) : AnyShapeStyle(Palette.glassHigh)))
                .widgetAccentable(ac.on)
            VStack(alignment: .leading, spacing: 0) {
                Text(ac.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text(ac.on ? "\(ac.modeName)\(ac.roomText.map { " · room \($0)" } ?? "")" : "Off\(ac.roomText.map { " · room \($0)" } ?? "")")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.faint).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(ac.targetText)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(ac.on ? Palette.text : Palette.muted)
                .contentTransition(.numericText(value: ac.target))
            ClimateButtons(ac: ac, size: 26)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ac.on ? ac.tint.opacity(0.3) : Palette.line))
    }

    /// The Mac's widest widget: the model beside scenes, rooms and climate.
    private func extraLarge(_ home: HomeSnapshot) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HomeTitle(home: home, size: 17)
                        LightsLine(home: home, size: 12)
                    }
                    Spacer()
                    AllLightsButton(home: home, size: 34)
                }
                HouseModel(home: home, padding: 8, interactive: true, boost: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Caption("Scenes")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                          spacing: 6) {
                    ForEach(home.scenes.prefix(6)) { scene in
                        SceneTile(scene: scene, active: scene.id == home.scene, compact: true).frame(height: 50)
                    }
                }
                Caption("Rooms").padding(.top, 2)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(home.roomsWithLights.prefix(6)) { room in roomRow(room, home) }
                }
                Spacer(minLength: 0)
                if let ac = home.acsOn.first ?? home.acs.first { climateStrip(ac) }
            }
            .frame(width: 310)
        }
    }

    private func roomRow(_ room: HomeSnapshot.Room, _ home: HomeSnapshot) -> some View {
        let lights = home.lights(in: room.id)
        let on = lights.filter(\.on)
        return Button(intent: ToggleRoomIntent(roomID: room.id, on: on.isEmpty)) {
            HStack(spacing: 8) {
                Circle().fill(on.isEmpty ? AnyShapeStyle(Palette.glassHigh) : AnyShapeStyle((on.first?.glow ?? Palette.warm).gradient))
                    .frame(width: 10, height: 10)
                    .widgetAccentable(!on.isEmpty)
                Text(room.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: 2)
                Text(on.isEmpty ? "Off" : "\(on.count)/\(lights.count)")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(on.isEmpty ? Palette.faint : Palette.warm)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(room.name): \(on.isEmpty ? "lights off" : "\(on.count) lights on")")
    }
}
