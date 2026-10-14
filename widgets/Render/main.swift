// Renders every widget as a PNG (2x by default) from a home snapshot, the way WidgetKit lays them out:
//   swift run render-widgets [snapshot.json] [output folder] [--tinted] [--size iphone|mac] [--scale 2]
// Without a snapshot it uses Resources/sample-home.json. A snapshot from a running app is
// in its App Group container, Widgets/home.json.
import SwiftUI
import WidgetKit
import AppIntents
import HouseCore
@testable import WidgetViews

var arguments = Array(CommandLine.arguments.dropFirst())
let tinted = arguments.contains("--tinted")
let mac = arguments.firstIndex(of: "--size").map { arguments.indices.contains($0 + 1) && arguments[$0 + 1] == "mac" } ?? false
let scale = arguments.firstIndex(of: "--scale").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 2
if let i = arguments.firstIndex(of: "--scale"), arguments.indices.contains(i + 1) { arguments.remove(at: i + 1) }
arguments.removeAll { $0.hasPrefix("--") || $0 == "mac" || $0 == "iphone" }
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let input = arguments.first.map { URL(fileURLWithPath: $0) } ?? here.appendingPathComponent("Resources/sample-home.json")
let output = URL(fileURLWithPath: arguments.dropFirst().first ?? "widget-renders", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let home = try JSONDecoder().decode(HomeSnapshot.self, from: Data(contentsOf: input))

/// Widget sizes in points: an iPhone 17 Pro's home screen, or the Mac's desktop.
let sizes: [WidgetFamily: CGSize] = mac
    ? [.systemSmall: .init(width: 170, height: 170), .systemMedium: .init(width: 364, height: 170),
       .systemLarge: .init(width: 364, height: 376), .systemExtraLarge: .init(width: 760, height: 376)]
    : [.systemSmall: .init(width: 170, height: 170), .systemMedium: .init(width: 364, height: 170),
       .systemLarge: .init(width: 364, height: 382), .systemExtraLarge: .init(width: 752, height: 382)]

struct Still<Content: View>: View {
    let family: WidgetFamily
    @ViewBuilder var content: Content

    var body: some View {
        let size = sizes[family] ?? .init(width: 170, height: 170)
        let accessory = false // Lock Screen widgets exist on the iPhone only; the simulator shows those
        ZStack {
            if !accessory { WidgetBackdrop(warmth: tinted ? 0 : min(1, Double(home.lightsOn) / 4)) }
            if tinted && !accessory { Color.black.opacity(0.35) }
            content
                .padding(accessory ? 0 : 16)
                .environment(\.stillFamily, family)
                .environment(\.stillRenderingMode, tinted || accessory ? .accented : .fullColor)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: accessory ? 12 : 23,
                                    style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
func render<V: View>(_ name: String, _ family: WidgetFamily, _ view: V) {
    let renderer = ImageRenderer(content: Still(family: family) { view })
    renderer.scale = scale
    guard let image = renderer.cgImage else { print("✗ \(name)"); return }
    let rep = NSBitmapImageRep(cgImage: image)
    let url = output.appendingPathComponent("\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("✓ \(url.path)")
}

let entry = HomeEntry(date: .now, home: home, isSample: false)
func configured<C: WidgetConfigurationIntent>(_ c: C) -> ConfiguredEntry<C> {
    ConfiguredEntry(date: .now, home: home, isSample: false, configuration: c)
}

MainActor.assumeIsolated {
    for family in HomeWidget.families {
        render("home-\(family.name)", family, HomeWidgetView(entry: entry))
    }
    for family in [WidgetFamily.systemSmall, .systemMedium] {
        render("scenes-\(family.name)", family, ScenesWidgetView(home: home))
    }
    var light = LightConfiguration()
    if let lamp = home.lights.first(where: { $0.on && $0.color != nil }) ?? home.lights.first {
        light.light = LightEntity(lamp, in: home)
    }
    render("light-small", .systemSmall, LightWidgetView(entry: configured(light)))
    var room = RoomConfiguration()
    if let first = home.roomsWithLights.first { room.room = RoomEntity(id: first.id, name: first.name) }
    render("room-medium", .systemMedium, RoomWidgetView(entry: configured(room)))
    render("room-large", .systemLarge, RoomWidgetView(entry: configured(room)))
    let climate = ClimateConfiguration()
    render("climate-small", .systemSmall, ClimateWidgetView(entry: configured(climate)))
    render("climate-medium", .systemMedium, ClimateWidgetView(entry: configured(climate)))
    #if os(iOS)
    if !mac {
        render("climate-circular", .accessoryCircular, ClimateWidgetView(entry: configured(climate)))
        render("climate-rectangular", .accessoryRectangular, ClimateWidgetView(entry: configured(climate)))
        render("light-circular", .accessoryCircular, LightWidgetView(entry: configured(light)))
        render("status-circular", .accessoryCircular, StatusWidgetView(home: home))
        render("status-rectangular", .accessoryRectangular, StatusWidgetView(home: home))
        render("status-inline", .accessoryInline, StatusWidgetView(home: home))
    }
    #endif
}

extension WidgetFamily {
    var name: String {
        switch self {
        case .systemSmall: return "small"
        case .systemMedium: return "medium"
        case .systemLarge: return "large"
        case .systemExtraLarge: return "xl"
        case .accessoryCircular: return "circular"
        case .accessoryRectangular: return "rectangular"
        case .accessoryInline: return "inline"
        default: return "other"
        }
    }
}
