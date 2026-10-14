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

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.settingsPath) {
            ScrollView {
                VStack(spacing: 30) {
                    homeSection
                    shortcutsSection
                    macSection
                    smartLifeSection
                    connectionsSection
                    aboutSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 32)
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
                case .smartLife: SmartLifeView()
                case .quickActions: QuickActionsView()
                }
            }
        }
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
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
                    planRow("custom", name: model.customPlanName ?? "My home", detail: customPlanDetail, symbol: "house.fill", tint: Theme.warm)
                    RowDivider()
                }
                planRow("home", name: "Apartment", detail: "Demo · 5 rooms, simulated devices", symbol: "building.2.fill", tint: Theme.accent)
                RowDivider()
                planRow("studio", name: "Studio", detail: "Demo · 3 rooms, simulated devices", symbol: "square.split.bottomrightquarter.fill", tint: Theme.accent)
            }
            Button { importing = true } label: {
                Label("Import a floor plan file…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(SecondaryButtonStyle())
            if !model.hasCustomPlan {
                footnote("Your own home is drawn in House Control on the Mac and arrives here when you pair the two.")
            }
        }
    }

    private var customPlanDetail: String {
        let devices = model.linkedDevices == 0 ? "No real devices linked"
            : "\(model.linkedDevices) real device\(model.linkedDevices == 1 ? "" : "s") linked"
        return model.activePlan == "custom" ? devices : "Your home"
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
            footnote("Press and hold the app icon for these. Widgets and Control Center buttons are added from the Home Screen and Control Center.")
        }
    }

    private var quickActionsDetail: String {
        let names = model.quickActions.chosen.compactMap(model.quickActions.lookup).map(\.title)
        return names.isEmpty ? "None" : names.joined(separator: " · ")
    }

    // MARK: - Mac

    private var macSection: some View {
        VStack(spacing: 10) {
            SectionTitle("Mac")
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
                    Text("The floor plan stays on this iPhone but no longer follows the Mac.")
                }
                footnote("Changes you save in the Mac's editor reach this iPhone while both are on the same Wi-Fi.")
            } else {
                Card(padding: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        IconBadge(symbol: "laptopcomputer.and.iphone", tint: Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bring your home over").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("Pair once and the floor plan you drew on the Mac — rooms, lamps, device links — shows up here and stays up to date.")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                NavigationLink(value: SettingsRoute.pairing) {
                    Label("Pair with Mac", systemImage: "qrcode.viewfinder")
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
        case .connected: return "Connected · up to date"
        case .connecting: return "Connecting…"
        case .failed: return "Not syncing"
        default:
            guard let last = model.lastSync else { return "Looking for it on this Wi-Fi…" }
            return "Last synced \(last.formatted(.relative(presentation: .named)))"
        }
    }

    // MARK: - Smart Life

    private var smartLifeSection: some View {
        VStack(spacing: 10) {
            SectionTitle("Smart Life")
            if model.smartLifeConnected {
                Card {
                    HStack(spacing: 14) {
                        IconBadge(symbol: "checkmark.seal.fill", tint: Theme.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.smartLifeAccount.isEmpty ? "Signed in" : model.smartLifeAccount)
                                .font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(model.linkedDevices == 0 ? "No devices linked in this floor plan"
                                 : "Controlling \(model.linkedDevices) device\(model.linkedDevices == 1 ? "" : "s")")
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
                        Text("Lights and air conditioners go back to being simulated on this iPhone.")
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

    // MARK: - Home Assistant, Hue, Apple Home

    private var connectionsSection: some View {
        VStack(spacing: 10) {
            SectionTitle("More connections")
            Card {
                serviceRow(symbol: "server.rack", tint: Color(red: 0.09, green: 0.74, blue: 0.95), title: "Home Assistant",
                           detail: model.homeAssistantName.map { "\($0) · from \(model.macName ?? "your Mac")" } ?? "Connect it on the Mac; it comes over by itself",
                           on: model.homeAssistantName != nil)
                RowDivider()
                serviceRow(symbol: "lightbulb.led.fill", tint: Color(red: 0.76, green: 0.55, blue: 1), title: "Philips Hue",
                           detail: model.hueName.map { "\($0) · from \(model.macName ?? "your Mac")" } ?? "Pair the bridge on the Mac; it comes over by itself",
                           on: model.hueName != nil)
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 70)
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
        case .off: return "Lamps, ACs and sensors from the Home app"
        case .waiting: return "Opening your homes…"
        case .denied: return "Not allowed. Turn on House Control in Settings → Privacy → HomeKit"
        case .ready(let homes, let accessories):
            if homes.isEmpty { return "No homes yet. Set one up in the Home app" }
            return "\(accessories) accessor\(accessories == 1 ? "y" : "ies") · \(homes.joined(separator: ", "))"
        }
    }

    private var homeKitFootnote: String {
        if case .ready = model.homeKit, model.macName != nil {
            return "Your Apple Home devices are listed in the Mac's editor, to link to the lamps and ACs of the plan. This iPhone switches them; macOS lets only App Store apps use HomeKit."
        }
        return "Home Assistant and Hue are set up once on the Mac and come over with the floor plan, over your paired, encrypted link."
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(spacing: 10) {
            SectionTitle("About")
            Card {
                infoRow("Version", value: version)
                RowDivider().padding(.leading, -52)
                infoRow("Privacy", value: "No account, no analytics")
            }
            footnote("House Control talks to your own devices: Tuya's servers for Smart Life, your Home Assistant, your Hue Bridge, Apple Home, and your Mac. Nothing else leaves this iPhone.")
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 16)).foregroundStyle(Theme.text)
            Spacer()
            Text(value).font(.system(size: 15)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
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
