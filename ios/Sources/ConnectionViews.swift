import SwiftUI
import HouseCore

/// Connects this iPhone to a Home Assistant server: found on the Wi-Fi by itself or typed
/// in, plus a long-lived access token. The paired Mac gets the connection too.
struct HomeAssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.insideEditor) private var insideEditor
    @State private var url = ""
    @State private var token = ""
    @State private var found: [[String: Any]] = []
    @State private var scanning = false
    @State private var busy = false
    @State private var problem: String?
    @State private var confirmDisconnect = false
    @FocusState private var focus: Field?

    private enum Field { case url, token }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                if let name = model.homeAssistantName {
                    connected(name)
                } else {
                    discovery
                    form
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.homeAssistantName)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle("Home Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .task { if model.homeAssistantName == nil { await scan() } }
    }

    // MARK: - Not connected

    private var discovery: some View {
        VStack(spacing: 10) {
            SectionTitle("On this Wi-Fi")
            Card {
                if scanning {
                    HStack(spacing: 12) {
                        ProgressView().tint(Theme.muted)
                        Text("Looking for Home Assistant…").font(.system(size: 15)).foregroundStyle(Theme.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 60)
                } else if found.isEmpty {
                    Text("None found by itself. Type its address below.")
                        .font(.system(size: 15)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(found.enumerated()), id: \.offset) { index, server in
                        if index > 0 { RowDivider() }
                        let address = server["url"] as? String ?? ""
                        Button {
                            url = address
                            focus = .token
                        } label: {
                            HStack(spacing: 14) {
                                IconBadge(symbol: "server.rack", tint: ConnectionLook.homeAssistant)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server["name"] as? String ?? "Home Assistant")
                                        .font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                                    Text(address).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: url == address ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(url == address ? Theme.accent : Theme.faint)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 66)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
            }
            if !scanning {
                Button { Task { await scan() } } label: { Label("Look again", systemImage: "dot.radiowaves.left.and.right") }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var form: some View {
        VStack(spacing: 10) {
            SectionTitle("Connect")
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    InputField(title: "Address", text: $url, prompt: "http://homeassistant.local:8123", focused: focus == .url) {
                        TextField("", text: $url)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .focused($focus, equals: .url)
                            .submitLabel(.next)
                            .onSubmit { focus = .token }
                    }
                    InputField(title: "Long-lived access token", text: $token, prompt: "Paste it here", focused: focus == .token) {
                        SecureField("", text: $token)
                            .focused($focus, equals: .token)
                            .submitLabel(.go)
                            .onSubmit(connect)
                    }
                }
            }
            if let problem {
                ProblemLabel(text: problem)
            }
            Button(action: connect) {
                if busy { ProgressView().tint(.white) } else { Text("Connect") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 4)

            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Where is the token?", systemImage: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("In Home Assistant open your profile (your name at the bottom of the sidebar) → **Security**. Under **Long-lived access tokens** tap **Create token**, name it “House Control” and copy it.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Footnote(text: "The token stays on this iPhone, in the Keychain, and goes to the Mac you paired, over your encrypted link. Lights, switches, climate devices and temperature sensors can then be linked to your plan.")
        }
    }

    private func scan() async {
        scanning = true
        found = await ServiceDiscovery.homeAssistants()
        scanning = false
        if url.isEmpty, found.count == 1 { url = found[0]["url"] as? String ?? "" }
    }

    private func connect() {
        focus = nil
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                try await model.connectHomeAssistant(url: url, token: token)
                token = ""
            } catch {
                problem = error.localizedDescription
                Haptics.shared.play("error")
            }
        }
    }

    // MARK: - Connected

    private func connected(_ name: String) -> some View {
        VStack(spacing: 10) {
            SectionTitle("Server")
            Card {
                HStack(spacing: 14) {
                    IconBadge(symbol: "server.rack", tint: ConnectionLook.homeAssistant)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                        HStack(spacing: 7) {
                            StatusDot(color: Theme.green)
                            Text(serverLine).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 70)
            }
            if !insideEditor {
                NavigationLink(value: SettingsRoute.devices) {
                    Label("Link devices to your plan", systemImage: "link")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
            }
            Button { confirmDisconnect = true } label: { Text("Disconnect") }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.red))
                .confirmationDialog("Disconnect Home Assistant?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) { model.disconnect(service: "homeassistant") }
                } message: {
                    Text("Its devices go back to being simulated, here and on your paired Mac.")
                }
            Footnote(text: "Connected on this iPhone or on your Mac, it works on both: they share the connection over their encrypted link.")
        }
        .transition(.opacity)
    }

    private var serverLine: String {
        let info = model.homeAssistantInfo
        return [info["url"] as? String, (info["version"] as? String).flatMap { $0.isEmpty ? nil : "version \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Pairs this iPhone with a Philips Hue Bridge: pick it, press its round button.
struct HueView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.insideEditor) private var insideEditor
    @State private var found: [[String: Any]] = []
    @State private var scanning = false
    @State private var host = ""
    @State private var pairing: [String: Any]?
    @State private var secondsLeft = 0
    @State private var problem: String?
    @State private var confirmDisconnect = false
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                if let name = model.hueName {
                    connected(name)
                } else if let pairing {
                    press(pairing)
                } else {
                    discovery
                    manual
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.hueName)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: pairing != nil)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle("Philips Hue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .task { if model.hueName == nil { await scan() } }
        // While waiting for the button: ask the bridge every two seconds, for a minute.
        .task(id: pairing.map { $0["host"] as? String ?? "" }) {
            guard let bridge = pairing else { return }
            for left in stride(from: 60, through: 0, by: -2) {
                secondsLeft = left
                do {
                    if try await model.pairHue(host: bridge["host"] as? String ?? "", bridgeId: bridge["bridgeId"] as? String,
                                               name: bridge["name"] as? String) {
                        pairing = nil
                        return
                    }
                } catch {
                    problem = error.localizedDescription
                    pairing = nil
                    Haptics.shared.play("error")
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
            }
            problem = "Nobody pressed the button in time. Try again."
            pairing = nil
        }
    }

    private var discovery: some View {
        VStack(spacing: 10) {
            SectionTitle("On this Wi-Fi")
            Card {
                if scanning {
                    HStack(spacing: 12) {
                        ProgressView().tint(Theme.muted)
                        Text("Looking for Hue Bridges…").font(.system(size: 15)).foregroundStyle(Theme.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 60)
                } else if found.isEmpty {
                    Text("No bridge found by itself. Type its address below — the Hue app shows it under Settings → My Hue System.")
                        .font(.system(size: 15)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(found.enumerated()), id: \.offset) { index, bridge in
                        if index > 0 { RowDivider() }
                        HStack(spacing: 14) {
                            IconBadge(symbol: "lightbulb.led.fill", tint: ConnectionLook.hue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bridge["name"] as? String ?? "Hue Bridge")
                                    .font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(bridge["host"] as? String ?? "").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 8)
                            Button("Pair") { start(bridge) }.buttonStyle(PillButtonStyle())
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 66)
                    }
                }
            }
            if let problem { ProblemLabel(text: problem) }
            if !scanning {
                Button { Task { await scan() } } label: { Label("Look again", systemImage: "dot.radiowaves.left.and.right") }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var manual: some View {
        VStack(spacing: 10) {
            SectionTitle("Or by address")
            Card(padding: 16) {
                InputField(title: "Bridge address", text: $host, prompt: "e.g. 192.168.1.20", focused: typing) {
                    TextField("", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($typing)
                        .submitLabel(.go)
                        .onSubmit { start(["host": host.trimmingCharacters(in: .whitespaces), "name": "Hue Bridge"]) }
                }
            }
            Button { start(["host": host.trimmingCharacters(in: .whitespaces), "name": "Hue Bridge"]) } label: { Text("Pair") }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            Footnote(text: "No account needed: the bridge lets one app in when its button is pressed. The key it gives stays on this iPhone and your paired Mac.")
        }
    }

    private func press(_ bridge: [String: Any]) -> some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.surfaceHigh).frame(width: 150, height: 150)
                Circle().strokeBorder(ConnectionLook.hue.opacity(0.7), lineWidth: 3).frame(width: 150, height: 150)
                    .phaseAnimator([1.0, 1.12]) { view, scale in view.scaleEffect(scale).opacity(2 - scale) }
                        animation: { _ in .easeInOut(duration: 1.1) }
                Circle().fill(Color.white.opacity(0.9)).frame(width: 56, height: 56)
                    .shadow(color: ConnectionLook.hue.opacity(0.8), radius: 18)
            }
            .padding(.top, 30)
            .accessibilityHidden(true)
            Text("Press the round button on the bridge")
                .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text("\(bridge["name"] as? String ?? "Hue Bridge") · waiting \(secondsLeft) s")
                .font(.system(size: 15)).foregroundStyle(Theme.muted)
                .contentTransition(.numericText(countsDown: true))
                .animation(.default, value: secondsLeft)
            Button("Cancel") { pairing = nil }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 10)
        }
    }

    private func start(_ bridge: [String: Any]) {
        typing = false
        problem = nil
        pairing = bridge
    }

    private func scan() async {
        scanning = true
        found = await ServiceDiscovery.hueBridges()
        scanning = false
    }

    private func connected(_ name: String) -> some View {
        VStack(spacing: 10) {
            SectionTitle("Bridge")
            Card {
                HStack(spacing: 14) {
                    IconBadge(symbol: "lightbulb.led.fill", tint: ConnectionLook.hue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                        HStack(spacing: 7) {
                            StatusDot(color: Theme.green)
                            Text(model.hueInfo["host"] as? String ?? "").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 70)
            }
            if !insideEditor {
                NavigationLink(value: SettingsRoute.devices) {
                    Label("Link devices to your plan", systemImage: "link")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
            }
            Button { confirmDisconnect = true } label: { Text("Disconnect") }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.red))
                .confirmationDialog("Disconnect the Hue Bridge?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) { model.disconnect(service: "hue") }
                } message: {
                    Text("Its lamps go back to being simulated, here and on your paired Mac.")
                }
        }
        .transition(.opacity)
    }
}

// MARK: - Shared pieces

extension EnvironmentValues {
    /// True on the connection screens opened from inside the editor, where the plan is being
    /// edited already (and "Devices" would change it behind the editor's back).
    @Entry var insideEditor = false
}

enum ConnectionLook {
    static let smartLife = Color(red: 1, green: 0.48, blue: 0.24)
    static let homeAssistant = Color(red: 0.09, green: 0.74, blue: 0.95)
    static let hue = Color(red: 0.76, green: 0.55, blue: 1)
    static let homeKit = Color(red: 1, green: 0.7, blue: 0.25)

    static func tint(_ service: String) -> Color {
        switch service {
        case "smartlife": smartLife
        case "homeassistant": homeAssistant
        case "hue": hue
        default: homeKit
        }
    }

    static func symbol(_ service: String) -> String {
        switch service {
        case "smartlife": "powerplug.fill"
        case "homeassistant": "server.rack"
        case "hue": "lightbulb.led.fill"
        default: "homekit"
        }
    }

    static func title(_ service: String) -> String {
        switch service {
        case "smartlife": "Smart Life"
        case "homeassistant": "Home Assistant"
        case "hue": "Philips Hue"
        default: "Apple Home"
        }
    }
}

/// A labelled text field in the style of the Smart Life screen.
struct InputField<Field: View>: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let focused: Bool
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt).font(.system(size: 17)).foregroundStyle(Theme.faint).allowsHitTesting(false)
                }
                field
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? Theme.accent : Theme.line))
        }
    }
}

struct ProblemLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Footnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}
