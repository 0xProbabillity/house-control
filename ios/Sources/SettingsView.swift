import SwiftUI
import UniformTypeIdentifiers
import HouseCore

/// Which home is shown, the link to the Mac and the Smart Life account.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var problem: String?
    @State private var confirmUnpair = false
    @State private var confirmSignOut = false
    @State private var newHome = false
    @State private var restoring: PlanStore.Earlier?

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.settingsPath) {
            ScrollView {
                VStack(spacing: 30) {
                    homeSection
                    shortcutsSection
                    macSection
                    #if SMART_LIFE
                    smartLifeSection
                    #endif
                    connectionsSection
                    aboutSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .readableWidth()
            }
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .pairing: PairingView()
                #if SMART_LIFE
                case .smartLife: SmartLifeView()
                #else
                case .smartLife: EmptyView()
                #endif
                case .quickActions: QuickActionsView()
                case .homeAssistant: HomeAssistantView()
                case .hue: HueView()
                case .homebridge: HomebridgeView()
                case .devices: DevicesView()
                case .language: LanguagePage()
                }
            }
        }
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $newHome) { NewHomeView().environment(model) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { try model.importPlan(from: try result.get()) }
            catch { problem = error.localizedDescription }
        }
        .alert("Could not open this floor plan", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    // MARK: - Home

    private var homeSection: some View {
        VStack(spacing: 10) {
            SectionTitle("Home")
            Card {
                if model.hasCustomPlan {
                    planRow("custom", name: model.customPlanName ?? String(localized: "My home", comment: "Name of the user's own home while it has none"), detail: customPlanDetail, symbol: "house.fill", tint: Theme.warm)
                    RowDivider()
                }
                planRow("home", name: String(localized: "Apartment", comment: "Settings: name of a demo home"),
                        detail: String(localized: "Demo · 5 rooms, simulated devices", comment: "Settings: under a demo home's name"), symbol: "building.2.fill", tint: Theme.accent)
                RowDivider()
                planRow("studio", name: String(localized: "Studio", comment: "Settings: name of a demo home, a studio apartment"),
                        detail: String(localized: "Demo · 3 rooms, simulated devices", comment: "Settings: under a demo home's name"), symbol: "square.split.bottomrightquarter.fill", tint: Theme.accent)
                RowDivider()
                planRow("house", name: String(localized: "House", comment: "Settings: name of a demo home, a house on two floors"),
                        detail: String(localized: "Demo · 2 floors, 10 rooms, simulated devices", comment: "Settings: under a demo home's name"), symbol: "stairs", tint: Theme.accent)
            }
            Card {
                Button { model.openEditor() } label: {
                    linkRow(symbol: "pencil.and.ruler.fill", tint: Theme.accent, title: String(localized: "Edit floor plan"),
                            detail: String(localized: "Rooms, lamps, air conditioners, furniture", comment: "Settings: under Edit floor plan"))
                }
                .buttonStyle(RowButtonStyle())
                RowDivider()
                NavigationLink(value: SettingsRoute.devices) {
                    linkRow(symbol: "link", tint: Theme.green, title: String(localized: "Devices", comment: "Settings row: links the plan's lamps and ACs to real devices"),
                            detail: model.linkedDevices == 0 ? String(localized: "Link the plan to your real devices")
                                : String(localized: "\(model.linkedDevices) linked to real devices", comment: "Settings: under Devices; the number of lamps and ACs of the plan linked to a real device"))
                }
                .buttonStyle(RowButtonStyle())
                #if ROOM_SCAN
                RowDivider()
                Button { model.openScan() } label: {
                    linkRow(symbol: "cube.transparent.fill", tint: Theme.warm, title: String(localized: "Scan with LiDAR"), beta: true,
                            detail: model.canScan ? String(localized: "Walk through your home, pin lamps and ACs as you go", comment: "Settings: under Scan with LiDAR")
                                : Device.isPad ? String(localized: "Needs an iPad with a LiDAR camera")
                                : String(localized: "Needs an iPhone with a LiDAR camera"))
                }
                .buttonStyle(RowButtonStyle())
                .disabled(!model.canScan)
                #endif
            }
            HStack(spacing: 10) {
                Button { newHome = true } label: { Label("New home", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { importing = true } label: { Label("Import file", systemImage: "square.and.arrow.down") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if !model.earlierHomes.isEmpty { earlierMenu }
            if !model.hasCustomPlan {
                footnote(String(localized: "Make your own home here, or pair with House Control on a Mac or PC and the one drawn there arrives by itself."))
            }
        }
        .confirmationDialog("Bring back \(restoring?.name ?? "")?", isPresented: Binding(
            get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
            Button("Bring back") { if let home = restoring { model.restoreEarlier(home) }; restoring = nil }
        } message: {
            Text(restoreMessage)
        }
    }

    private var restoreMessage: String {
        guard let mac = model.macName else {
            return Device.isPad
                ? String(localized: "It becomes this iPad's home again. The one here now is kept among the earlier homes.")
                : String(localized: "It becomes this iPhone's home again. The one here now is kept among the earlier homes.")
        }
        return Device.isPad
            ? String(localized: "It becomes the home on this iPad and on \(mac). The one here now is kept among the earlier homes.", comment: "The placeholder is the paired computer's name")
            : String(localized: "It becomes the home on this iPhone and on \(mac). The one here now is kept among the earlier homes.", comment: "The placeholder is the paired computer's name")
    }

    /// The homes kept before a scan, the computer or a file replaced the one here.
    private var earlierMenu: some View {
        Menu {
            ForEach(model.earlierHomes.prefix(12)) { home in
                Button { restoring = home } label: {
                    Text(home.name)
                    Text(verbatim: [String(localized: "\(home.rooms) rooms", comment: "Earlier homes menu: how many rooms a kept home has"),
                                    String(localized: "\(home.devices) devices", comment: "Earlier homes menu: how many devices a kept home has")]
                        .formatted(.list(type: .and, width: .narrow)) + " · " + home.date.formatted(date: .abbreviated, time: .shortened))
                }
            }
        } label: {
            Label("Earlier homes", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private func linkRow(symbol: String, tint: Color, title: String, beta: Bool = false, detail: String) -> some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                    #if ROOM_SCAN
                    if beta { BetaBadge() }
                    #endif
                }
                Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 66)
        .contentShape(Rectangle())
    }

    private var customPlanDetail: String {
        let devices = model.linkedDevices == 0 ? String(localized: "No real devices linked", comment: "Settings: under the user's own home")
            : String(localized: "\(model.linkedDevices) real devices linked", comment: "Settings: under the user's own home")
        return model.activePlan == "custom" ? devices : String(localized: "Your home", comment: "Settings: under the user's own home while a demo is shown")
    }

    private func planRow(_ id: String, name: String, detail: String, symbol: String, tint: Color) -> some View {
        Button { model.selectPlan(id) } label: {
            HStack(spacing: 14) {
                IconBadge(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: model.activePlan == id ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(model.activePlan == id ? Theme.accent : Theme.faint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 66)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityAddTraits(model.activePlan == id ? .isSelected : [])
    }

    // MARK: - Quick actions

    private var shortcutsSection: some View {
        VStack(spacing: 10) {
            SectionTitle("Shortcuts")
            Card {
                NavigationLink(value: SettingsRoute.quickActions) {
                    HStack(spacing: 14) {
                        IconBadge(symbol: "hand.tap.fill", tint: Theme.warm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quick Actions").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(quickActionsDetail).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 66)
                }
                .buttonStyle(RowButtonStyle())
            }
            footnote(String(localized: "Press and hold the app icon for these. Widgets and Control Center buttons are added from the Home Screen and Control Center."))
        }
    }

    private var quickActionsDetail: String {
        let names = model.quickActions.chosen.compactMap(model.quickActions.lookup).map(\.title)
        return names.isEmpty ? String(localized: "None", comment: "Settings: no quick actions chosen") : names.joined(separator: " · ")
    }

    // MARK: - Mac

    private var macSection: some View {
        VStack(spacing: 10) {
            SectionTitle("Mac or PC")
            if let name = model.macName {
                Card {
                    HStack(spacing: 14) {
                        IconBadge(symbol: "laptopcomputer", tint: Theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                            HStack(spacing: 7) {
                                StatusDot(color: syncColor, pulsing: syncPulsing)
                                Text(syncText).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 70)
                    if case .failed(let reason) = model.syncStatus {
                        RowDivider()
                        Text(reason)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }
                HStack(spacing: 10) {
                    Button { model.syncNow() } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(SecondaryButtonStyle())
                    Button { confirmUnpair = true } label: { Text("Unpair") }
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.red))
                        .frame(maxWidth: 120)
                }
                .confirmationDialog("Unpair from \(name)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                    Button("Unpair", role: .destructive) { model.unpair() }
                } message: {
                    Text(Device.isPad ? String(localized: "The floor plan stays on this iPad but no longer follows the computer.")
                         : String(localized: "The floor plan stays on this iPhone but no longer follows the computer."))
                }
                footnote(String(localized: "Changes saved on either one reach the other while both are on the same Wi-Fi: the floor plan, device links, Home Assistant, Hue and Homebridge."))
            } else {
                Card(padding: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        IconBadge(symbol: "laptopcomputer.and.iphone", tint: Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Optional: a Mac or PC").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("Pair with House Control on a Mac or PC and your home — rooms, lamps, device links, connections — stays the same on both, whichever one you edit.")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                NavigationLink(value: SettingsRoute.pairing) {
                    Label("Pair with Mac or PC", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var syncColor: Color {
        switch model.syncStatus {
        case .connected: Theme.green
        case .failed: Theme.red
        default: Theme.warm
        }
    }

    private var syncPulsing: Bool {
        switch model.syncStatus {
        case .searching, .connecting: true
        default: false
        }
    }

    private var syncText: String {
        switch model.syncStatus {
        case .connected: return String(localized: "Connected · up to date", comment: "Settings: the paired computer's sync status")
        case .connecting: return String(localized: "Connecting…", comment: "Settings: the paired computer's sync status")
        case .failed: return String(localized: "Not syncing", comment: "Settings: the paired computer's sync status")
        default:
            guard let last = model.lastSync else { return String(localized: "Looking for it on this Wi-Fi…", comment: "Settings: looking for the paired computer") }
            return String(localized: "Last synced \(last.formatted(.relative(presentation: .named)))", comment: "Settings: the paired computer's sync status; the placeholder is a relative time such as “5 minutes ago” or “yesterday”")
        }
    }

    // MARK: - Smart Life

    #if SMART_LIFE
    private var smartLifeSection: some View {
        VStack(spacing: 10) {
            SectionTitle("Smart Life")
            if model.smartLifeConnected && model.smartLifeExpired {
                Card(padding: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        IconBadge(symbol: "exclamationmark.triangle.fill", tint: Theme.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sign-in expired").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(Device.isPad
                                 ? String(localized: "Smart Life no longer accepts this iPad's sign-in, so lights and air conditioners can't be switched. Scan the QR code again to reconnect; your floor plan and links stay as they are.")
                                 : String(localized: "Smart Life no longer accepts this iPhone's sign-in, so lights and air conditioners can't be switched. Scan the QR code again to reconnect; your floor plan and links stay as they are."))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                NavigationLink(value: SettingsRoute.smartLife) {
                    Label("Reconnect Smart Life", systemImage: "qrcode")
                }
                .buttonStyle(SecondaryButtonStyle())
            } else if model.smartLifeConnected {
                Card {
                    HStack(spacing: 14) {
                        IconBadge(symbol: "checkmark.seal.fill", tint: Theme.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.smartLifeAccount.isEmpty ? String(localized: "Signed in", comment: "Settings: Smart Life account when its name is unknown") : model.smartLifeAccount)
                                .font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(model.linkedDevices == 0 ? String(localized: "No devices linked in this floor plan")
                                 : String(localized: "Controlling \(model.linkedDevices) devices", comment: "Settings: under the Smart Life account; how many devices of the plan it switches"))
                                .font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 70)
                }
                Button { confirmSignOut = true } label: { Text("Sign out") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.red))
                    .confirmationDialog("Sign out of Smart Life?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button("Sign out", role: .destructive) { model.signOut() }
                    } message: {
                        Text(Device.isPad ? String(localized: "Lights and air conditioners go back to being simulated on this iPad.")
                             : String(localized: "Lights and air conditioners go back to being simulated on this iPhone."))
                    }
            } else {
                Card(padding: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        IconBadge(symbol: "lightbulb.2.fill", tint: Theme.warm)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Not signed in").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("Sign in with your Smart Life or Tuya Smart account and the lamps and air conditioners linked to it in your floor plan become the real ones.")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                NavigationLink(value: SettingsRoute.smartLife) {
                    Label("Connect Smart Life", systemImage: "link")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
    #endif

    // MARK: - Home Assistant, Hue, Homebridge, Apple Home

    private var connectionsSection: some View {
        VStack(spacing: 10) {
            if AppModel.includesSmartLife { SectionTitle("More connections") } else { SectionTitle("Connections") }
            Card {
                NavigationLink(value: SettingsRoute.homeAssistant) {
                    serviceRow(symbol: "server.rack", tint: ConnectionLook.homeAssistant, title: "Home Assistant",
                               detail: model.homeAssistantName ?? String(localized: "Connect your server", comment: "Settings: under Home Assistant while not connected"), on: model.homeAssistantName != nil)
                }
                .buttonStyle(RowButtonStyle())
                RowDivider()
                NavigationLink(value: SettingsRoute.hue) {
                    serviceRow(symbol: "lightbulb.led.fill", tint: ConnectionLook.hue, title: "Philips Hue",
                               detail: model.hueName ?? String(localized: "Pair your Hue Bridge", comment: "Settings: under Philips Hue while not connected"), on: model.hueName != nil)
                }
                .buttonStyle(RowButtonStyle())
                RowDivider()
                NavigationLink(value: SettingsRoute.homebridge) {
                    serviceRow(symbol: ConnectionLook.symbol("homebridge"), tint: ConnectionLook.homebridge, title: "Homebridge",
                               detail: model.homebridgeExpired ? String(localized: "Sign in again", comment: "Settings: under Homebridge when its session ran out")
                                   : model.homebridgeName ?? String(localized: "Plugins for hundreds of brands", comment: "Settings: under Homebridge while not connected"),
                               on: model.homebridgeName != nil && !model.homebridgeExpired)
                }
                .buttonStyle(RowButtonStyle())
                RowDivider()
                homeKitRow
            }
            footnote(homeKitFootnote)
        }
    }

    private func serviceRow(symbol: String, tint: Color, title: String, detail: String, on: Bool) -> some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                HStack(spacing: 7) {
                    if on { StatusDot(color: Theme.green, pulsing: false) }
                    Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 70)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var homeKitRow: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: "homekit", tint: Color(red: 1, green: 0.7, blue: 0.25))
            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Home").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                HStack(spacing: 7) {
                    if case .ready = model.homeKit { StatusDot(color: Theme.green, pulsing: false) }
                    Text(homeKitDetail).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            switch model.homeKit {
            case .off:
                Button("Connect") { model.connectHomeKit() }.buttonStyle(PillButtonStyle())
            case .waiting:
                ProgressView().tint(Theme.muted)
            case .denied:
                Button("Allow") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(PillButtonStyle())
            case .ready:
                Button("Turn off") { model.disconnectHomeKit() }.buttonStyle(PillButtonStyle(tint: Theme.muted))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 70)
        .animation(.snappy, value: model.homeKit)
    }

    private var homeKitDetail: String {
        switch model.homeKit {
        case .off: return String(localized: "Lamps, ACs and sensors from the Home app", comment: "Settings: under Apple Home while not connected")
        case .waiting: return String(localized: "Opening your homes…", comment: "Settings: under Apple Home while HomeKit loads")
        case .denied: return String(localized: "Not allowed. Turn on House Control in Settings → Privacy → HomeKit", comment: "Settings: under Apple Home; the path is in iOS Settings")
        case .ready(let homes, let accessories):
            if homes.isEmpty { return String(localized: "No homes yet. Set one up in the Home app") }
            let count = String(localized: "\(accessories) accessories", comment: "Settings: under Apple Home; how many HomeKit accessories it has. The names of the homes follow")
            return ([count] + homes).joined(separator: " · ")
        }
    }

    private var homeKitFootnote: String {
        if case .ready = model.homeKit, model.macName != nil {
            return Device.isPad
                ? String(localized: "This iPad switches your Apple Home devices; your paired computer lists them for its editor, but only the iPad app may use HomeKit.")
                : String(localized: "This iPhone switches your Apple Home devices; your paired computer lists them for its editor, but only the iPhone app may use HomeKit.")
        }
        return String(localized: "Home Assistant, Hue and Homebridge set up here or on your paired computer work on both, shared over your encrypted link.")
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(spacing: 10) {
            SectionTitle("About")
            Card {
                NavigationLink(value: SettingsRoute.language) {
                    LanguageRow { linkRow(symbol: "character.bubble.fill", tint: Theme.accent,
                                          title: String(localized: "Language", comment: "Settings: the app's language"), detail: $0) }
                }
                .buttonStyle(RowButtonStyle())
            }
            Card {
                infoRow("Version", value: version)
                RowDivider().padding(.leading, -52)
                infoRow("Privacy", value: String(localized: "No account, no analytics", comment: "Settings › About: next to Privacy"))
            }
            footnote(privacyFootnote)
            Card {
                webRow(About.website, symbol: "globe", tint: Theme.accent, title: String(localized: "Website", comment: "Settings › About: link to the app's website"),
                       detail: String(localized: "Features, help and the Mac app", comment: "Settings › About: under Website"))
                RowDivider()
                webRow(About.privacy, symbol: "hand.raised.fill", tint: Theme.green, title: String(localized: "Privacy Policy"),
                       detail: String(localized: "Nothing is collected", comment: "Settings › About: under Privacy Policy"))
                RowDivider()
                webRow(About.support, symbol: "questionmark.circle.fill", tint: Theme.warm, title: String(localized: "Support", comment: "Settings › About: link to the support page"),
                       detail: String(localized: "Questions and problems", comment: "Settings › About: under Support"))
            }
            SectionTitle("Developer").padding(.top, 20)
            Card {
                webRow(About.x, symbol: "at", tint: Theme.text, title: String(localized: "\(About.developer) on X", comment: "Settings › Developer: link to the developer's profile on X (Twitter); the placeholder is the developer's name"),
                       detail: "@0xProbabillity")
                RowDivider()
                webRow(About.github, symbol: "chevron.left.forwardslash.chevron.right", tint: Theme.text,
                       title: String(localized: "\(About.developer) on GitHub", comment: "Settings › Developer: link to the developer's GitHub profile; the placeholder is the developer's name"),
                       detail: "github.com/0xProbabillity")
                RowDivider()
                webRow(About.source, symbol: "shippingbox.fill", tint: Theme.text, title: String(localized: "Source code", comment: "Settings › Developer: link to the app's source code"),
                       detail: String(localized: "House Control is open source", comment: "Settings › Developer: under Source code"))
            }
        }
    }

    private var privacyFootnote: String {
        switch (AppModel.includesSmartLife, Device.isPad) {
        case (true, false): String(localized: "House Control talks to your own devices: Tuya's servers for Smart Life, your Home Assistant, your Hue Bridge, your Homebridge, Apple Home, and your paired computer. Nothing else leaves this iPhone.")
        case (true, true): String(localized: "House Control talks to your own devices: Tuya's servers for Smart Life, your Home Assistant, your Hue Bridge, your Homebridge, Apple Home, and your paired computer. Nothing else leaves this iPad.")
        case (false, false): String(localized: "House Control talks to your own devices: your Home Assistant, your Hue Bridge, your Homebridge, Apple Home, and your paired computer. Nothing else leaves this iPhone.")
        case (false, true): String(localized: "House Control talks to your own devices: your Home Assistant, your Hue Bridge, your Homebridge, Apple Home, and your paired computer. Nothing else leaves this iPad.")
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }

    private func infoRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 16)).foregroundStyle(Theme.text)
            Spacer()
            Text(value).font(.system(size: 15)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    /// A row that opens a web page in the browser.
    private func webRow(_ url: URL, symbol: String, tint: Color, title: String, detail: String) -> some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                IconBadge(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityHint("Opens in Safari")
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}
