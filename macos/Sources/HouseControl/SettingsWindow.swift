import AppKit
import SwiftUI
import HouseCore

/// What the Settings window shows. The app delegate fills it in whenever the window comes up
/// or something it shows changes, and carries out what it asks for.
@MainActor
final class SettingsModel: ObservableObject {
    struct Plan: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct Connection: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let tint: Color
        let detail: String
        let connected: Bool
    }

    @Published var openAtLogin: LoginItem.State = .off
    @Published var islandShown = false
    @Published var plans: [Plan] = []
    @Published var activePlan = "home"
    @Published var connections: [Connection] = []
    @Published var phones: [String] = []
    @Published var aiLive = false

    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var setIsland: (Bool) -> Void = { _ in }
    var selectPlan: (String) -> Void = { _ in }
    var editHome: () -> Void = {}
    var loadPlan: () -> Void = {}
    var revealPlan: () -> Void = {}
    var openConnection: (String) -> Void = { _ in }
    var pairPhone: () -> Void = {}
    var openAgent: () -> Void = {}
    var stopAgent: () -> Void = {}
    var revealLog: () -> Void = {}
}

/// House Control → Settings… (⌘,): the app's options in one window, the way every Mac app has
/// them. The panel's gear menu and the menu bar icon's right-click menu lead here too.
@MainActor
final class SettingsWindowController: NSWindowController {
    let model = SettingsModel()
    var onShow: (() -> Void)?

    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes: [(String, String, AnyView)] = [
            ("General", "gearshape", AnyView(GeneralPane())),
            ("Home", "house", AnyView(HomePane())),
            ("Connections", "point.3.connected.trianglepath.dotted", AnyView(ConnectionsPane())),
            ("iPhone", "iphone", AnyView(PhonePane())),
            ("AI Access", "sparkles", AnyView(AgentPane())),
            ("About", "info.circle", AnyView(AboutPane())),
        ]
        for (title, symbol, view) in panes {
            let host = NSHostingController(rootView: view.environmentObject(model))
            host.sizingOptions = .preferredContentSize
            host.title = title // the tab controller names the window after the pane on show
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HouseControlSettings")
        super.init(window: window)
    }

    /// The window as a PNG, drawn without the screen (HOUSE_SNAPSHOT_DIR).
    func snapshot(to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(pane: String? = nil) {
        onShow?()
        if let pane, let tabs = window?.contentViewController as? NSTabViewController,
           let index = tabs.tabViewItems.firstIndex(where: { $0.label == pane }) {
            tabs.selectedTabViewItemIndex = index
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Panes

/// One pane: a grouped form of a fixed width, the height of what is in it.
private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin == .on }, set: model.setOpenAtLogin))
                if model.openAtLogin == .needsApproval {
                    LabeledContent {
                        Button("Open Login Items…") { model.setOpenAtLogin(true) }
                    } label: {
                        Text("Waiting for your OK in System Settings → General → Login Items.")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Footnote("House Control starts with your Mac and waits in the menu bar.")
            }
            Section {
                Toggle("Show the Island", isOn: Binding(get: { model.islandShown }, set: model.setIsland))
            } footer: {
                Footnote("Lamps on, the AC and scenes at a glance, in the middle of the menu bar. Click it to open it up.")
            }
            Section("Getting around") {
                Tip(symbol: "cursorarrow.click", text: "Click the house in the menu bar for the panel.")
                Tip(symbol: "contextualmenu.and.cursorarrow", text: "Right-click it for the menu: editor, iPhone, AI Access.")
                Tip(symbol: "command", text: "⌘, opens these settings from any House Control window.")
            }
        }
    }
}

private struct HomePane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                Picker("Floor plan", selection: Binding(get: { model.activePlan }, set: model.selectPlan)) {
                    ForEach(model.plans) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Footnote("Draw your own home in the editor, or load a plan file. The demos are simulated: nothing real switches.")
            }
            Section {
                ActionRow(symbol: "pencil.and.ruler", title: "Edit Home…", detail: "Rooms, lamps, ACs, furniture and scenes", action: model.editHome)
                ActionRow(symbol: "square.and.arrow.down", title: "Load Floor Plan…", detail: "A plan file from another Mac or a backup", action: model.loadPlan)
                ActionRow(symbol: "folder", title: "Reveal Plan File", detail: "The plan as JSON, in the Finder", action: model.revealPlan)
            }
        }
    }
}

private struct ConnectionsPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                ForEach(model.connections) { connection in
                    LabeledContent {
                        Button(connection.connected ? "Manage…" : "Connect…") { model.openConnection(connection.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Badge(symbol: connection.symbol, tint: connection.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.name)
                                HStack(spacing: 5) {
                                    Circle().fill(connection.connected ? Color.green : Color.secondary.opacity(0.5))
                                        .frame(width: 6, height: 6)
                                    Text(connection.detail).foregroundStyle(.secondary).font(.callout)
                                }
                            }
                        }
                    }
                }
            } footer: {
                Footnote("Connections are set up in the editor, where you also link each lamp and AC to its real device. Home Assistant and Hue are shared with a paired iPhone.")
            }
        }
    }
}

private struct PhonePane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                if model.phones.isEmpty {
                    Label("No iPhone is connected right now", systemImage: "iphone.slash").foregroundStyle(.secondary)
                } else {
                    ForEach(model.phones, id: \.self) { phone in
                        Label { Text(phone) } icon: { Image(systemName: "iphone").foregroundStyle(.green) }
                    }
                }
                ActionRow(symbol: "qrcode", title: "Pair iPhone…", detail: "Show the code to scan with House Control on the iPhone", action: model.pairPhone)
            } footer: {
                Footnote("Paired, the iPhone gets this floor plan and its connections and keeps them in step with the Mac, whichever one you edit. An iPhone stays connected while its app is open.")
            }
        }
    }
}

private struct AgentPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                LabeledContent {
                    if model.aiLive { Button("Stop", role: .destructive, action: model.stopAgent) }
                } label: {
                    HStack(spacing: 10) {
                        Badge(symbol: "sparkles", tint: .purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Access")
                            Text(model.aiLive ? "Live: an assistant can run your home" : "Off")
                                .foregroundStyle(model.aiLive ? .green : .secondary).font(.callout)
                        }
                    }
                }
                ActionRow(symbol: "link", title: "Open AI Access…", detail: "The link and what an assistant may do", action: model.openAgent)
            } footer: {
                Footnote("A private link that lets an AI assistant such as Claude or ChatGPT see and switch your home, with the limits you choose. It ends when you stop it or quit House Control.")
            }
        }
    }
}

private struct AboutPane: View {
    @EnvironmentObject var model: SettingsModel
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""

    var body: some View {
        Pane {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("House Control").font(.title3.weight(.semibold))
                        Text(version.isEmpty ? "Development build" : "Version \(version)\(build.isEmpty || build == version ? "" : " (\(build))")")
                            .foregroundStyle(.secondary)
                        Text("Your home as a live 3D model, in the menu bar.").foregroundStyle(.secondary).font(.callout)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LinkRow(symbol: "globe", title: "Website", url: About.website)
                LinkRow(symbol: "questionmark.circle", title: "Support", url: About.support)
                LinkRow(symbol: "hand.raised", title: "Privacy Policy", url: About.privacy)
                LinkRow(symbol: "shippingbox", title: "Source Code", url: About.source)
                LinkRow(symbol: "at", title: "\(About.developer) on X", url: About.x)
            }
            Section {
                ActionRow(symbol: "doc.text.magnifyingglass", title: "Reveal Device Log", detail: "What was sent to your devices, for a bug report", action: model.revealLog)
            }
        }
    }
}

// MARK: - Pieces

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Badge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
    }
}

/// A row that does something: a title and what it is for, and the whole row is the button.
private struct ActionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LinkRow: View {
    let symbol: String
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
