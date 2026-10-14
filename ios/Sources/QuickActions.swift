import SwiftUI
import UIKit
import HouseCore

/// One entry of the menu that opens when the app's icon is pressed and held.
struct QuickAction: Identifiable, Hashable {
    enum Group: String, CaseIterable {
        case scenes = "Scenes", home = "Whole home", lights = "Lights", climate = "Air conditioners"
    }

    /// "scene:cozy", "lights:off", "lights:on", "light:<id>", "ac:<id>": stored, and carried by the icon's menu item.
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let group: Group

    /// What it does; toggles stay toggles, decided by the panel when the action runs.
    static func action(for id: String) -> HomeAction? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "scene": return .scene(parts[1])
        case "lights": return .allLights(on: parts[1] == "on")
        case "light": return .light(parts[1])
        case "ac": return .acPower(parts[1])
        default: return nil
        }
    }

    /// Everything the home offers, in the order the editor lists it.
    static func catalog(for home: HomeSnapshot) -> [QuickAction] {
        var out = home.scenes.map {
            QuickAction(id: "scene:\($0.id)", title: $0.name, subtitle: "Scene", symbol: $0.symbol, group: .scenes)
        }
        out.append(QuickAction(id: "lights:off", title: "All Lights Off", subtitle: home.name, symbol: "lightbulb.slash", group: .home))
        out.append(QuickAction(id: "lights:on", title: "All Lights On", subtitle: home.name, symbol: "lightbulb.2.fill", group: .home))
        for light in home.lights {
            out.append(QuickAction(id: "light:\(light.id)", title: light.name, subtitle: home.room(light.room)?.name,
                                   symbol: light.symbol, group: .lights))
        }
        for ac in home.acs {
            out.append(QuickAction(id: "ac:\(ac.id)", title: ac.name, subtitle: home.room(ac.room)?.name,
                                   symbol: "air.conditioner.horizontal.fill", group: .climate))
        }
        return out
    }
}

/// The quick actions of the app icon: which ones, in which order, for each home.
@MainActor
@Observable
final class QuickActions {
    /// iOS shows four of an app's own items.
    static let limit = 4
    static let itemType = "io.github.0xprobabillity.HouseControl.quick"

    private(set) var available: [QuickAction] = []
    /// The ids on the icon, in order.
    var chosen: [String] = [] {
        didSet {
            guard chosen != oldValue, let identity else { return }
            UserDefaults.standard.set(chosen, forKey: "quickActions.\(identity)")
            apply()
        }
    }
    @ObservationIgnored private var identity: String?

    func lookup(_ id: String) -> QuickAction? { available.first { $0.id == id } }

    /// Follows the home the panel shows: another plan has its own set.
    func update(home: HomeSnapshot) {
        let catalog = QuickAction.catalog(for: home)
        let changed = catalog != available
        available = catalog
        if identity != home.identity {
            identity = nil // no saving while switching
            let saved = UserDefaults.standard.stringArray(forKey: "quickActions.\(home.identity)")
            chosen = (saved ?? Self.defaults(for: home)).filter { id in catalog.contains { $0.id == id } }
            identity = home.identity
            apply()
        } else if changed {
            apply()
        }
    }

    /// Three scenes and "All Lights Off" until the person picks their own.
    private static func defaults(for home: HomeSnapshot) -> [String] {
        let preferred = ["cozy", "movie", "night", "bright"]
        var scenes = preferred.filter { id in home.scenes.contains { $0.id == id } }
        for scene in home.scenes where !scenes.contains(scene.id) { scenes.append(scene.id) }
        return scenes.prefix(3).map { "scene:\($0)" } + ["lights:off"]
    }

    func add(_ id: String) {
        guard chosen.count < Self.limit, !chosen.contains(id) else { return }
        chosen.append(id)
    }

    func remove(_ id: String) { chosen.removeAll { $0 == id } }

    private func apply() {
        UIApplication.shared.shortcutItems = chosen.compactMap(lookup).map {
            UIApplicationShortcutItem(type: Self.itemType, localizedTitle: $0.title, localizedSubtitle: $0.subtitle,
                                      icon: UIApplicationShortcutIcon(systemImageName: $0.symbol),
                                      userInfo: ["id": $0.id as NSString])
        }
    }
}

/// Where an item picked from the icon's menu arrives: at launch, or while the app runs.
@MainActor
enum QuickActionCenter {
    static var handler: ((_ id: String, _ title: String) -> Void)? {
        didSet { if handler != nil { flush() } }
    }
    private static var pending: [(String, String)] = []

    static func receive(_ item: UIApplicationShortcutItem) {
        guard item.type == QuickActions.itemType, let id = item.userInfo?["id"] as? String else { return }
        pending.append((id, item.localizedTitle))
        flush()
    }

    private static func flush() {
        guard let handler else { return }
        let items = pending
        pending = []
        for (id, title) in items { handler(id, title) }
    }
}

/// Hands SwiftUI's scenes a delegate that hears about the icon's menu.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { MainActor.assumeIsolated { QuickActionCenter.receive(item) } }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { QuickActionCenter.receive(shortcutItem) }
        completionHandler(true)
    }
}

// MARK: - Editor

/// Settings → Quick Actions: what the icon's menu offers, in which order.
struct QuickActionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let quick = model.quickActions
        List {
            Section {
                IconPreview(items: quick.chosen.compactMap(quick.lookup))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                if quick.chosen.isEmpty {
                    Text("Nothing yet: add up to four below.")
                        .font(.system(size: 14.5)).foregroundStyle(Theme.muted)
                        .listRowBackground(Theme.surface)
                }
                ForEach(quick.chosen, id: \.self) { id in
                    if let action = quick.lookup(id) {
                        row(action, chosen: true)
                    }
                }
                .onMove { quick.chosen.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { quick.chosen.remove(atOffsets: $0) }
            } header: {
                header("On the icon · \(quick.chosen.count) of \(QuickActions.limit)")
            } footer: {
                Text("Press and hold House Control on the Home Screen. Drag to reorder, swipe to remove.")
                    .font(.system(size: 13)).foregroundStyle(Theme.faint)
            }
            ForEach(QuickAction.Group.allCases, id: \.self) { group in
                let items = quick.available.filter { $0.group == group && !quick.chosen.contains($0.id) }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { row($0, chosen: false) }
                    } header: {
                        header(group.rawValue)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Quick Actions")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: quick.chosen)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .bold)).kerning(1.1).foregroundStyle(Theme.faint)
    }

    private func row(_ action: QuickAction, chosen: Bool) -> some View {
        let quick = model.quickActions
        let full = quick.chosen.count >= QuickActions.limit
        return HStack(spacing: 12) {
            IconBadge(symbol: action.symbol, tint: chosen ? Theme.warm : Theme.accent, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                if let subtitle = action.subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            if !chosen {
                Button { quick.add(action.id) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 24))
                        .foregroundStyle(full ? Theme.faint : Theme.green)
                }
                .buttonStyle(.plain)
                .disabled(full)
                .accessibilityLabel("Add \(action.title)")
            }
        }
        .padding(.vertical, 3)
        .listRowBackground(Theme.surface)
        .deleteDisabled(!chosen)
        .moveDisabled(!chosen)
    }
}

/// The icon's menu as it will look, above the list.
private struct IconPreview: View {
    let items: [QuickAction]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image("AppIconPreview")
                .resizable()
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                            if let subtitle = item.subtitle {
                                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        Image(systemName: item.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                }
                if items.isEmpty {
                    Text("No quick actions").font(.system(size: 14)).foregroundStyle(Theme.faint).frame(height: 46)
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview: \(items.map(\.title).joined(separator: ", "))")
    }
}
