import SwiftUI
import WidgetKit
import AppIntents
import HouseCore

/// A scene as a rounded tile: icon over name, lit when it is the home's scene.
struct SceneTile: View {
    let scene: HomeSnapshot.Scene
    let active: Bool
    var compact = false
    private let look = WidgetLook()

    var body: some View {
        Button(intent: ApplySceneIntent(sceneID: scene.id)) {
            VStack(spacing: compact ? 3 : 5) {
                Image(systemName: scene.symbol)
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    .foregroundStyle(active ? Color.white : scene.tint)
                    .widgetAccentable()
                Text(scene.name)
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                .strokeBorder(active ? Color.white.opacity(0.28) : Palette.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(scene.name) scene\(active ? ", active" : "")")
    }

    private var background: AnyShapeStyle {
        guard look.fullColor else { return AnyShapeStyle(Color.white.opacity(active ? 0.28 : 0.1)) }
        if active {
            return AnyShapeStyle(LinearGradient(colors: [Palette.accent, Color(hex: "#2a63d6")], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(Palette.glass)
    }
}

/// A round button: every lamp off (or on, when they all are off).
struct AllLightsButton: View {
    let home: HomeSnapshot
    var size: CGFloat = 34

    var body: some View {
        let anyOn = home.lightsOn > 0
        Button(intent: AllLightsIntent(on: !anyOn)) {
            Image(systemName: "power")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(anyOn ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "#5aa2ff"), Palette.accent],
                                                                               startPoint: .top, endPoint: .bottom))
                                                : AnyShapeStyle(Palette.glassHigh)))
                .shadow(color: anyOn ? Palette.accent.opacity(0.55) : .clear, radius: 8, y: 2)
                .widgetAccentable(anyOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(anyOn ? "Turn every light off" : "Turn every light on")
    }
}

/// A lamp as the panel draws it: icon in a rounded square, name, state; tap to switch.
struct LightTile: View {
    let light: HomeSnapshot.Light
    var room: String?
    private let look = WidgetLook()

    var body: some View {
        Button(intent: ToggleLightIntent(lightID: light.id)) {
            HStack(spacing: 9) {
                Image(systemName: light.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(light.on ? Color(hex: "#3a2208") : Palette.muted)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(light.on ? AnyShapeStyle(light.glow.gradient) : AnyShapeStyle(Palette.glassHigh)))
                    .widgetAccentable(light.on)
                VStack(alignment: .leading, spacing: 1) {
                    Text(light.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text(room.map { "\($0) · \(light.stateText)" } ?? light.stateText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(light.on ? light.glow.opacity(0.95) : Palette.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(tileBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(light.on ? light.glow.opacity(0.35) : Palette.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(light.name), \(light.on ? "on" : "off")")
    }

    private var tileBackground: AnyShapeStyle {
        guard look.fullColor else { return AnyShapeStyle(Color.white.opacity(light.on ? 0.22 : 0.08)) }
        return light.on ? AnyShapeStyle(LinearGradient(colors: [light.glow.opacity(0.26), light.glow.opacity(0.1)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Palette.glass)
    }
}

/// An AC's set-point on an arc from its minimum to its maximum, with the room's reading.
struct ClimateDial: View {
    let ac: HomeSnapshot.AC
    var lineWidth: CGFloat = 7

    var body: some View {
        let span = max(1, ac.max - ac.min)
        let fraction = (ac.target - ac.min) / span
        let roomFraction = ac.roomTemp.map { min(1, max(0, ($0 - ac.min) / span)) }
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * fraction)
                .stroke(ac.on ? AnyShapeStyle(AngularGradient(colors: [ac.tint.opacity(0.55), ac.tint],
                                                              center: .center, startAngle: .degrees(0), endAngle: .degrees(270 * fraction)))
                              : AnyShapeStyle(Color.white.opacity(0.28)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .widgetAccentable()
            if let roomFraction {
                // The room's own temperature, as a small notch on the arc.
                Circle().fill(Color.white).frame(width: lineWidth * 0.62, height: lineWidth * 0.62)
                    .offset(y: -1)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .rotationEffect(.degrees(-135 + 270 * roomFraction))
            }
        }
        .padding(lineWidth / 2)
    }
}

/// −  ⏻  + for an AC.
struct ClimateButtons: View {
    let ac: HomeSnapshot.AC
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            step(-1, "minus")
            Button(intent: ACPowerIntent(acID: ac.id)) {
                Image(systemName: "power")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(ac.on ? AnyShapeStyle(ac.tint.gradient) : AnyShapeStyle(Palette.glassHigh)))
                    .widgetAccentable(ac.on)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ac.on ? "Turn \(ac.name) off" : "Turn \(ac.name) on")
            step(1, "plus")
        }
    }

    private func step(_ delta: Int, _ symbol: String) -> some View {
        Button(intent: ACStepIntent(acID: ac.id, step: delta)) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Palette.text)
                .frame(width: size, height: size)
                .background(Circle().fill(Palette.glass))
                .overlay(Circle().strokeBorder(Palette.line))
        }
        .buttonStyle(.plain)
        .disabled(delta < 0 ? ac.target <= ac.min : ac.target >= ac.max)
        .accessibilityLabel(delta < 0 ? "Cooler" : "Warmer")
    }
}

/// "House Control" with the app's mark, for headers.
struct HomeTitle: View {
    let home: HomeSnapshot
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: home.lightsOn > 0 || !home.acsOn.isEmpty ? "house.fill" : "house")
                .font(.system(size: size * 0.86, weight: .semibold))
                .foregroundStyle(Palette.warm)
                .widgetAccentable()
            Text(home.name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
        }
    }
}

/// "● 6 of 11 lights on".
struct LightsLine: View {
    let home: HomeSnapshot
    var size: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(home.lightsOn > 0 ? Palette.green : Palette.faint).frame(width: 6, height: 6)
            Text(home.lightsLine)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

/// "❄︎ Cool 23° · 26.6° room" for the first AC that runs (or the first one).
struct ClimateLine: View {
    let home: HomeSnapshot
    var size: CGFloat = 11.5

    var body: some View {
        if let ac = home.acsOn.first ?? home.acs.first {
            HStack(spacing: 5) {
                Image(systemName: ac.on ? ac.modeSymbol : "air.conditioner.horizontal")
                    .font(.system(size: size * 0.9, weight: .bold))
                    .foregroundStyle(ac.tint)
                    .widgetAccentable()
                Text(ac.on ? "\(ac.modeName) \(ac.targetText)" : "AC off")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Palette.text)
                if let room = ac.roomText {
                    Text("· \(room) inside")
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(Palette.faint)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}
