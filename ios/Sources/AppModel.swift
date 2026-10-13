import SwiftUI
import HouseCore

/// A short message that slides in under the status bar.
struct Banner: Equatable, Identifiable {
    let id = UUID()
    var symbol: String
    var text: String
    var tint: Color = Theme.accent
}

/// Where the settings sheet opens.
enum SettingsRoute: Hashable {
    case pairing
    case smartLife
}

/// Everything the screens share: the floor plan, the devices, the link to the Mac.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let plans = PlanStore()
    @ObservationIgnored let hub: DeviceHub
    @ObservationIgnored let sync: SyncClient
    @ObservationIgnored let web: HomeWeb
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private var active = false

    // Floor plan
    private(set) var activePlan: String
    private(set) var hasCustomPlan: Bool
    private(set) var customPlanName: String?
    private(set) var linkedDevices = 0

    // Mac sync
    private(set) var syncStatus: SyncClient.Status
    private(set) var macName: String?
    private(set) var lastSync: Date?

    // Smart Life
    private(set) var smartLifeConnected: Bool
    private(set) var smartLifeAccount: String
    /// The User Code entered on the Mac, offered here so it need not be typed again.
    private(set) var suggestedUserCode = ""

    // Presentation
    var showSettings = false
    var settingsPath: [SettingsRoute] = []
    var showWelcome = false
    private(set) var banner: Banner?

    init() {
        let environment = ProcessInfo.processInfo.environment
        // HOUSE_DATA_DIR (SIMCTL_CHILD_HOUSE_DATA_DIR in the simulator) runs the app on a
        // throw-away folder: nothing goes to the Keychain or the saved panel state.
        let sandboxed = !(environment["HOUSE_DATA_DIR"] ?? "").isEmpty
        let directory = plans.directory
        func secret(_ name: String) -> SecretStore {
            sandboxed ? FileSecretStore(url: directory.appendingPathComponent("\(name).json"))
                      : KeychainSecretStore(service: "io.github.0xprobabillity.HouseControl", account: name)
        }
        hub = DeviceHub(directory: directory, session: secret("smartlife"))
        sync = SyncClient(store: secret("sync"))
        web = HomeWeb(persistent: !sandboxed)

        activePlan = plans.activePlan
        hasCustomPlan = plans.hasCustomPlan
        customPlanName = plans.customPlanName
        syncStatus = sync.status
        macName = sync.pairing?.name
        smartLifeConnected = hub.isSmartLifeConnected
        smartLifeAccount = hub.smartLifeAccount
        lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date

        hub.onStale = { [weak self] in self?.poll() }
        reloadLinks()

        sync.deviceName = UIDevice.current.name
        sync.planRevision = { [plans] in plans.customPlanRevision }
        sync.onStatus = { [weak self] in
            guard let self else { return }
            self.syncStatus = self.sync.status
        }
        sync.onState = { [weak self] in self?.received($0) }

        web.onMessage = { [weak self] in self?.handle($0) }
        web.load { [weak self] in self?.bootPayload() ?? [:] }

        // HOUSE_SCREEN=settings|pairing|smartlife|welcome opens the app there (screenshots, UI checks).
        switch environment["HOUSE_SCREEN"] {
        case "settings": showSettings = true
        case "pairing": showSettings = true; settingsPath = [.pairing]
        case "smartlife": showSettings = true; settingsPath = [.smartLife]
        case "welcome": showWelcome = true
        case "home": break
        default: showWelcome = !sandboxed && !UserDefaults.standard.bool(forKey: "welcomed")
        }
    }

    // MARK: - Life cycle

    /// The app came to the foreground (true) or left it (false).
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            sync.start()
            startPolling()
        } else {
            sync.stop()
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard active, pageReady, hub.canPoll else { return }
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        Task { @MainActor in
            guard let update = await hub.poll() else { return }
            web.call("applyRemote", update)
        }
    }

    // MARK: - Web UI

    private func bootPayload() -> [String: Any] {
        var boot = plans.bootPayload()
        boot["smartLife"] = hub.smartLifeInfo
        if let device = ProcessInfo.processInfo.environment["HOUSE_OPEN_DEVICE"] { boot["openDevice"] = device }
        return boot
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            pageReady = true
            web.call("shown") // the camera sweep and the lights coming on, once per load
            startPolling()
        case "command":
            hub.command(message) { [weak self] in self?.web.reply(to: message, $0) }
        case "haptic":
            Haptics.shared.play(message["kind"] as? String ?? "light")
        case "openSettings":
            settingsPath = []
            showSettings = true
        default:
            break
        }
    }

    private func reloadLinks() {
        hub.setLinks(from: plans.activePlan == "custom" ? plans.customPlan() : nil)
        linkedDevices = hub.linkedDeviceCount
    }

    /// Re-reads everything that depends on the plan and shows it.
    private func reloadHome() {
        activePlan = plans.activePlan
        hasCustomPlan = plans.hasCustomPlan
        customPlanName = plans.customPlanName
        reloadLinks()
        pageReady = false
        web.reload()
    }

    // MARK: - Floor plans

    func selectPlan(_ plan: String) {
        guard plan != activePlan else { return }
        plans.select(plan)
        reloadHome()
    }

    /// Takes a plan file picked in Files as this phone's home.
    func importPlan(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try plans.importPlan(from: url)
        reloadHome()
        show(Banner(symbol: "checkmark.circle.fill", text: "Floor plan imported", tint: Theme.green))
    }

    func removeCustomPlan() {
        plans.removeCustom()
        reloadHome()
    }

    // MARK: - Mac sync

    /// A `housecontrol://pair?…` link, from the camera, the clipboard or another app.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let pairing = SyncPairing(link: url.absoluteString) else { return false }
        pair(pairing)
        return true
    }

    func pair(_ pairing: SyncPairing) {
        sync.pair(pairing)
        macName = pairing.name
        UserDefaults.standard.set(true, forKey: "welcomed")
        Haptics.shared.play("success")
        if active { sync.start() }
    }

    func unpair() {
        sync.unpair()
        macName = nil
        lastSync = nil
        suggestedUserCode = ""
        UserDefaults.standard.removeObject(forKey: "lastSync")
    }

    func syncNow() { sync.refresh() }

    private func received(_ state: SyncState) {
        macName = state.macName
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: "lastSync")
        suggestedUserCode = state.userCode
        guard let data = state.plan, (try? PlanStore.validate(data)) != nil else { return }
        // The first plan from the Mac becomes this phone's home; later ones only replace it
        // (someone who switched to a demo plan stays there).
        let first = !plans.hasCustomPlan
        do {
            try plans.saveCustom(data: data, select: first || plans.activePlan == "custom")
        } catch {
            show(Banner(symbol: "exclamationmark.triangle.fill", text: "Could not save the floor plan", tint: Theme.red))
            return
        }
        reloadHome()
        Haptics.shared.play("success")
        show(Banner(symbol: "arrow.triangle.2.circlepath",
                    text: first ? "\(plans.customPlanName ?? "Your home") arrived from \(state.macName)"
                                : "Updated from \(state.macName)"))
    }

    // MARK: - Smart Life

    func beginLogin(userCode: String) async throws -> (token: String, qrContent: String) {
        try await hub.beginLogin(userCode: userCode)
    }

    /// True once the login was confirmed in the Smart Life app.
    func finishLogin(token: String, userCode: String) async -> Bool {
        guard await hub.finishLogin(token: token, userCode: userCode) else { return false }
        smartLifeConnected = hub.isSmartLifeConnected
        smartLifeAccount = hub.smartLifeAccount
        sync.showQR(nil)
        Haptics.shared.play("success")
        startPolling()
        return true
    }

    /// Asks the paired Mac to display the login code; false when it is not connected.
    func showOnMac(_ qrContent: String?) -> Bool { sync.showQR(qrContent) }

    func signOut() {
        hub.signOut()
        smartLifeConnected = false
        smartLifeAccount = ""
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Welcome, banners

    func finishWelcome(pairing: Bool) {
        UserDefaults.standard.set(true, forKey: "welcomed")
        showWelcome = false
        guard pairing else { return }
        settingsPath = [.pairing]
        // One sheet has to be gone before the next can come up.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            showSettings = true
        }
    }

    func show(_ new: Banner) {
        bannerTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { banner = new }
        bannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { banner = nil }
        }
    }
}
