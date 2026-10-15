import SwiftUI
import HouseCore
#if SMART_LIFE
import HouseSmartLife
#endif

/// A short message that slides in under the status bar.
struct Banner: Equatable, Identifiable {
    let id = UUID()
    var symbol: String
    var text: String
    var tint: Color = Theme.accent
}

enum HomeKitStatus: Equatable {
    case off
    /// Asking iOS, or waiting for HomeKit to load the homes.
    case waiting
    case denied
    case ready(homes: [String], accessories: Int)
}

/// Where the settings sheet opens.
enum SettingsRoute: Hashable, Identifiable {
    case pairing
    case smartLife
    case quickActions
    case homeAssistant
    case hue
    case devices

    var id: Self { self }

    /// The screen a connection id of the web editor ("smartlife", "hue"…) stands for.
    init?(service: String) {
        switch service {
        case "smartlife" where AppModel.includesSmartLife: self = .smartLife
        case "homeassistant": self = .homeAssistant
        case "hue": self = .hue
        default: return nil
        }
    }
}

/// Both this iPhone and the paired Mac changed the floor plan since they last agreed:
/// the user picks which one stays.
struct PlanChoice: Identifiable {
    let id = UUID()
    let macName: String
    let macPlanName: String
    let phonePlanName: String
    /// The Mac's plan, byte for byte.
    let macPlan: Data
}

/// Everything the screens share: the floor plan, the devices, the link to the Mac.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let plans = PlanStore()
    @ObservationIgnored let hub: DeviceHub
    @ObservationIgnored let sync: SyncClient
    @ObservationIgnored let web: HomeWeb
    /// The Home Screen and Lock Screen widgets, and the Control Center controls.
    @ObservationIgnored let widgets = WidgetBridge()
    /// The menu of the app's icon on the Home Screen.
    let quickActions = QuickActions()
    /// A quick action picked before the page was up.
    @ObservationIgnored private var pendingQuick: [(HomeAction, String)] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private var active = false
    /// A device a widget asked to show before the page was up.
    @ObservationIgnored private var pendingDevice: String?

    // Floor plan
    private(set) var activePlan: String
    private(set) var hasCustomPlan: Bool
    private(set) var customPlanName: String?
    private(set) var linkedDevices = 0
    /// Goes up whenever the plan on disk changed, so views reading `currentPlan` redraw.
    private(set) var planVersion = 0

    // Mac sync
    private(set) var syncStatus: SyncClient.Status
    private(set) var macName: String?
    private(set) var lastSync: Date?

    // Home Assistant and Hue (shared by the Mac), Apple Home (this phone's own)
    private(set) var homeAssistantName: String?
    private(set) var hueName: String?
    private(set) var homeKit: HomeKitStatus = .off
    @ObservationIgnored let homeKitService = HomeKitService()

    // Smart Life: only in the builds that include it (TestFlight). The App Store edition is
    // built without the HouseSmartLife module, so none of its code is in that app.
    #if SMART_LIFE
    nonisolated static let includesSmartLife = true
    #else
    nonisolated static let includesSmartLife = false
    #endif
    private(set) var smartLifeConnected = false
    private(set) var smartLifeAccount = ""
    /// The User Code entered on the Mac, offered here so it need not be typed again.
    private(set) var suggestedUserCode = ""

    // Editing the home on this phone
    /// The web editor, while it is open.
    private(set) var editorWeb: HomeWeb?
    var showEditor = false
    /// A connection screen opened from inside the editor.
    var editorSheet: SettingsRoute?
    /// The editor asked for a plan file to import (`importPlan`), or to save one (`exportPlan`).
    var editorImporting = false
    var editorExport: PlanFile?
    @ObservationIgnored private var editorPending: [String: Any]?
    var planChoice: PlanChoice?

    // Presentation
    var showSettings = false
    var settingsPath: [SettingsRoute] = []
    var showWelcome = false
    var showNewHome = false
    private(set) var banner: Banner?

    init() {
        let environment = ProcessInfo.processInfo.environment
        // HOUSE_DATA_DIR (SIMCTL_CHILD_HOUSE_DATA_DIR in the simulator) runs the app on a
        // throw-away folder: nothing goes to the Keychain or the saved panel state.
        let sandboxed = !(environment["HOUSE_DATA_DIR"] ?? "").isEmpty
        let directory = plans.directory
        func secret(_ name: String) -> SecretStore {
            sandboxed ? FileSecretStore(url: directory.appendingPathComponent("\(name).json"))
                      : KeychainSecretStore(service: Bundle.main.bundleIdentifier ?? "HouseControl", account: name)
        }
        #if SMART_LIFE
        hub = DeviceHub(directory: directory, secret: secret, homeKit: homeKitService, cloud: SmartLifePlatform.init)
        #else
        hub = DeviceHub(directory: directory, secret: secret, homeKit: homeKitService)
        #endif
        sync = SyncClient(store: secret("sync"))
        web = HomeWeb(persistent: !sandboxed)

        activePlan = plans.activePlan
        hasCustomPlan = plans.hasCustomPlan
        customPlanName = plans.customPlanName
        syncStatus = sync.status
        macName = sync.pairing?.name
        #if SMART_LIFE
        smartLifeConnected = hub.smartLife?.isSmartLifeConnected ?? false
        smartLifeAccount = hub.smartLife?.account ?? ""
        #endif
        lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date

        hub.onStale = { [weak self] in self?.poll() }
        homeKitService.onCatalogChange = { [weak self] in
            guard let self else { return }
            self.refreshConnections()
            self.sendCatalog()
            self.startPolling()
        }
        reloadLinks()
        refreshConnections()
        // A phone paired before plans travelled both ways holds the Mac's plan as it was sent.
        if sync.isPaired, syncedRevision == nil { syncedRevision = plans.customPlanRevision }

        sync.deviceName = UIDevice.current.name
        sync.planRevision = { [plans] in plans.customPlanRevision }
        sync.onStatus = { [weak self] in
            guard let self else { return }
            self.syncStatus = self.sync.status
        }
        sync.onState = { [weak self] in self?.received($0) }

        widgets.onActions = { [weak self] run, adopt in
            guard let self else { return }
            if !run.isEmpty { self.web.call("widget", run) }
            if let adopt { self.web.call("adopt", adopt) }
        }
        widgets.onSnapshot = { [weak self] in self?.quickActions.update(home: $0) }
        QuickActionCenter.handler = { [weak self] id, title in self?.runQuickAction(id, title: title) }
        web.onMessage = { [weak self] in self?.handle($0) }
        web.load { [weak self] in self?.bootPayload() ?? [:] }

        // HOUSE_SCREEN=settings|pairing|smartlife|welcome opens the app there (screenshots, UI checks).
        switch environment["HOUSE_SCREEN"] {
        case "settings": showSettings = true
        case "pairing": showSettings = true; settingsPath = [.pairing]
        case "smartlife": showSettings = true; settingsPath = [.smartLife]
        case "quickactions": showSettings = true; settingsPath = [.quickActions]
        case "homeassistant": showSettings = true; settingsPath = [.homeAssistant]
        case "hue": showSettings = true; settingsPath = [.hue]
        case "devices": showSettings = true; settingsPath = [.devices]
        case "editor": showEditor = true; openEditor()
        case "connections": showSettings = true
        case "welcome": showWelcome = true
        case "newhome": showNewHome = true
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
            widgets.takeActions()
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
        #if SMART_LIFE
        boot["smartLife"] = hub.smartLife?.smartLifeInfo
        #endif
        if let device = ProcessInfo.processInfo.environment["HOUSE_OPEN_DEVICE"] { boot["openDevice"] = device }
        return boot
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            pageReady = true
            widgets.isReady = true
            if let device = pendingDevice {
                pendingDevice = nil
                web.call("openDevice", device)
            }
            let quick = pendingQuick
            pendingQuick = []
            for (action, title) in quick { run(action, title: title) }
            web.call("shown") // the camera sweep and the lights coming on, once per load
            startPolling()
        case "command":
            hub.command(message) { [weak self] in self?.web.reply(to: message, $0) }
        case "widgets":
            widgets.publish(message)
        case "haptic":
            Haptics.shared.play(message["kind"] as? String ?? "light")
        case "openSettings":
            settingsPath = []
            showSettings = true
        case "openEditor":
            openEditor()
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
        planVersion += 1
        activePlan = plans.activePlan
        hasCustomPlan = plans.hasCustomPlan
        customPlanName = plans.customPlanName
        reloadLinks()
        pageReady = false
        widgets.isReady = false
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

    /// The plan the phone shows right now, as stored: the user's own, or a demo from the app.
    var currentPlan: [String: Any]? {
        _ = planVersion
        if plans.activePlan == "custom", let plan = plans.customPlan() { return plan }
        let url = HomeWeb.assetRoot.appendingPathComponent("plans/\(plans.activePlan).json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Stores an edited plan as this phone's home (a demo becomes the user's own), shows it
    /// and hands it to the Mac.
    func savePlan(_ plan: [String: Any]) throws {
        let data = try PlanStore.encode(plan)
        _ = try PlanStore.validate(data)
        try plans.saveCustom(data: data)
        reloadHome()
        sync.sendPlan(data) // when the Mac is away, the next sync sends it
    }

    /// Starts a new home on this phone: an empty one with one room, or a copy of a demo
    /// layout. The editor opens on it.
    func createHome(name: String, template: String?) {
        var plan = template.flatMap { id -> [String: Any]? in
            let url = HomeWeb.assetRoot.appendingPathComponent("plans/\(id).json")
            return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        } ?? PlanEditor.blank(name: name)
        plan["name"] = name
        do {
            try savePlan(plan)
        } catch {
            show(Banner(symbol: "exclamationmark.triangle.fill", text: "Could not create the home", tint: Theme.red))
            return
        }
        showSettings = false
        showNewHome = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            openEditor()
        }
    }

    // MARK: - Editor

    func openEditor() {
        if editorWeb == nil {
            let web = HomeWeb(persistent: (ProcessInfo.processInfo.environment["HOUSE_DATA_DIR"] ?? "").isEmpty, mode: "editor")
            web.onMessage = { [weak self, weak web] message in
                guard let self, let web else { return }
                self.handleEditor(message, web)
            }
            web.load { [weak self] in self?.editorBoot() ?? [:] }
            editorWeb = web
        }
        showSettings = false
        showEditor = true
    }

    /// Called once the editor's screen is gone.
    func editorClosed() {
        editorWeb?.detach()
        editorWeb = nil
        editorSheet = nil
    }

    private func editorBoot() -> [String: Any] {
        var boot = plans.bootPayload()
        if boot["config"] == nil, let plan = currentPlan { boot["config"] = plan }
        #if SMART_LIFE
        boot["smartLife"] = hub.smartLife?.smartLifeInfo
        boot["tuya"] = hub.smartLife?.tuyaInfo
        #endif
        boot["services"] = hub.servicesInfo
        if let section = ProcessInfo.processInfo.environment["HOUSE_OPEN_EDITOR"] { boot["section"] = section }
        return boot
    }

    private func handleEditor(_ message: [String: Any], _ web: HomeWeb) {
        switch message["type"] as? String {
        case "close":
            showEditor = false
        case "haptic":
            Haptics.shared.play(message["kind"] as? String ?? "light")
        case "openConnection":
            let service = message["service"] as? String ?? ""
            if service == "homekit" {
                // Apple Home has no screen of its own: iOS asks for access, Settings grants it.
                switch homeKit {
                case .off: connectHomeKit()
                case .denied: if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                default: show(Banner(symbol: "homekit", text: "Apple Home is connected"))
                }
            } else {
                editorSheet = SettingsRoute(service: service)
            }
        case "savePlan":
            guard let config = message["config"] as? [String: Any] else { return }
            do {
                try savePlan(config)
                Haptics.shared.play("success")
                web.reply(to: message, ["ok": true])
            } catch {
                web.reply(to: message, ["error": error.localizedDescription])
            }
        case "importPlan":
            editorPending = message
            editorImporting = true
        case "exportPlan":
            guard let config = message["config"] as? [String: Any], let data = try? PlanStore.encode(config) else { return }
            editorPending = message
            editorExport = PlanFile(data: data, name: config["name"] as? String ?? "Home")
        default:
            handleService(message) { web.reply(to: message, $0) }
        }
    }

    /// The file picked for the editor's "Import…" (nil: cancelled).
    func editorImported(_ result: Result<URL, Error>?) {
        guard let message = editorPending, let web = editorWeb else { return }
        editorPending = nil
        guard case .success(let url) = result else {
            web.reply(to: message, ["cancelled": true])
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            web.reply(to: message, ["error": "This file is not a floor plan."])
            return
        }
        web.reply(to: message, ["config": json])
    }

    func editorExported(_ ok: Bool) {
        guard let message = editorPending else { return }
        editorPending = nil
        editorExport = nil
        editorWeb?.reply(to: message, ok ? ["ok": true] : ["cancelled": true])
    }

    /// A connection screen opened from the editor was closed: the editor's lists follow.
    func editorSheetClosed() {
        editorWeb?.call("servicesChanged", hub.servicesInfo)
    }

    /// What the web editor asks of the platforms; the same calls the Mac answers.
    private func handleService(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        switch message["type"] as? String {
        case "services.info":
            reply(hub.servicesInfo)
        case "devices.all":
            Task { @MainActor in
                let (devices, errors) = await hub.allDevices()
                reply(["devices": devices, "errors": errors])
            }
        case "services.discover":
            let service = message["service"] as? String ?? ""
            Task { @MainActor in
                let found = service == "hue" ? await ServiceDiscovery.hueBridges() : await ServiceDiscovery.homeAssistants()
                reply(["found": found])
            }
        case "homeassistant.connect":
            Task { @MainActor in
                do {
                    try await connectHomeAssistant(url: message["url"] as? String ?? "", token: message["token"] as? String ?? "")
                    reply(hub.servicesInfo)
                } catch {
                    reply(["error": error.localizedDescription])
                }
            }
        case "hue.pair":
            Task { @MainActor in
                do {
                    if try await pairHue(host: message["host"] as? String ?? "", bridgeId: message["bridgeId"] as? String,
                                         name: message["name"] as? String) {
                        reply(hub.servicesInfo)
                    } else {
                        reply(["waiting": true])
                    }
                } catch {
                    reply(["error": error.localizedDescription])
                }
            }
        case "service.disconnect":
            disconnect(service: message["service"] as? String ?? "")
            reply(hub.servicesInfo)
        #if SMART_LIFE
        case "smartlife.begin":
            Task { @MainActor in
                do {
                    let login = try await beginLogin(userCode: message["userCode"] as? String ?? "")
                    let png = QRCode.png(for: login.qrContent).map { "data:image/png;base64,\($0.base64EncodedString())" }
                    reply(["token": login.token, "qr": png ?? ""])
                } catch {
                    reply(["error": error.localizedDescription])
                }
            }
        case "smartlife.poll":
            Task { @MainActor in
                let done = await finishLogin(token: message["token"] as? String ?? "", userCode: message["userCode"] as? String ?? "")
                reply(["connected": done, "info": smartLife.smartLifeInfo])
            }
        case "smartlife.signOut":
            signOut()
            reply(smartLife.smartLifeInfo)
        case "tuya.devices":
            Task { @MainActor in
                do { reply(["devices": try await smartLife.listDevices()]) } catch { reply(["error": error.localizedDescription]) }
            }
        case "tuya.save":
            do {
                try smartLife.saveTuya(accessId: message["accessId"] as? String ?? "", accessSecret: message["accessSecret"] as? String ?? "",
                                 region: message["region"] as? String ?? "eu")
                reply(smartLife.tuyaInfo)
            } catch {
                reply(["error": error.localizedDescription])
            }
        #endif
        default:
            break
        }
    }

    // MARK: - Devices (linking without the editor)

    /// Every device of every connected platform, plus what went wrong with the ones that
    /// could not be asked.
    func allDevices() async -> (devices: [[String: Any]], errors: [String: String]) {
        await hub.allDevices()
    }

    /// Applies an edit to the current plan and saves it.
    func editPlan(_ change: (inout PlanEditor) -> Void) {
        guard let plan = currentPlan else { return }
        var editor = PlanEditor(plan: plan)
        change(&editor)
        do {
            try savePlan(editor.plan)
        } catch {
            show(Banner(symbol: "exclamationmark.triangle.fill", text: "Could not save the floor plan", tint: Theme.red))
        }
    }

    // MARK: - Quick actions

    private func runQuickAction(_ id: String, title: String) {
        guard let action = QuickAction.action(for: id) else { return }
        showSettings = false
        if pageReady { run(action, title: title) } else { pendingQuick.append((action, title)) }
    }

    /// Runs an action from the icon's menu through the panel, which sends it to the devices.
    private func run(_ action: HomeAction, title: String) {
        guard let data = try? JSONEncoder().encode(action),
              let dict = try? JSONSerialization.jsonObject(with: data) else { return }
        web.call("widget", [dict])
        Haptics.shared.play("medium")
        show(Banner(symbol: action.kind == .scene ? "sparkles" : "checkmark.circle.fill", text: title))
    }

    // MARK: - Mac sync

    /// A `housecontrol://pair?…` link, from the camera, the clipboard or another app, or
    /// `housecontrol://open?device=…` from a widget.
    @discardableResult
    func open(_ url: URL) -> Bool {
        if url.scheme == SyncPairing.scheme, url.host == "open" {
            showSettings = false
            let device = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "device" }?.value
            if let device {
                if pageReady { web.call("openDevice", device) } else { pendingDevice = device }
            }
            return true
        }
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
        syncedRevision = nil
        planChoice = nil
        macName = nil
        lastSync = nil
        suggestedUserCode = ""
        UserDefaults.standard.removeObject(forKey: "lastSync")
    }

    func syncNow() { sync.refresh() }

    /// The plan revision this phone and the Mac last agreed on: tells which side changed it.
    private var syncedRevision: String? {
        get { UserDefaults.standard.string(forKey: "syncedPlanRevision") }
        set { UserDefaults.standard.set(newValue, forKey: "syncedPlanRevision") }
    }

    private func received(_ state: SyncState) {
        macName = state.macName
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: "lastSync")
        suggestedUserCode = state.userCode
        if let shared = state.connections, hub.adoptConnections(shared) {
            refreshConnections()
            reloadLinks()
            startPolling()
        }
        // Whatever this phone connected (or disconnected) since goes the other way.
        sync.sendConnections(hub.shareableConnections, userCode: smartLifeUserCode)
        sendCatalog()
        reconcilePlan(with: state)
    }

    /// Decides which way the floor plan goes: to whichever side did not change it since the
    /// two last agreed. When both did, the user chooses.
    private func reconcilePlan(with state: SyncState) {
        let local = plans.customPlanRevision
        let remote = state.revision
        if let local, local == remote {
            syncedRevision = local
            planChoice = nil
            return
        }
        guard let local, let localData = try? Data(contentsOf: plans.customPlanURL) else {
            // Nothing of our own: the Mac's plan, if it has one, is the home.
            if !remote.isEmpty { adopt(state) }
            return
        }
        if remote.isEmpty || remote == syncedRevision {
            // Only this phone changed it (or the Mac has none yet): the Mac takes ours.
            sync.sendPlan(localData)
        } else if local == syncedRevision {
            adopt(state)
        } else if let macPlan = state.plan {
            let theirs = (try? PlanStore.validate(macPlan))?["name"] as? String ?? "Home"
            planChoice = PlanChoice(macName: state.macName, macPlanName: theirs,
                                    phonePlanName: plans.customPlanName ?? "Home", macPlan: macPlan)
        }
    }

    /// Takes the Mac's plan as this phone's home.
    private func adopt(_ state: SyncState) {
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
        syncedRevision = PlanStore.revision(of: data)
        reloadHome()
        editorWeb?.call("planArrived", plans.customPlan() ?? [:], state.macName)
        Haptics.shared.play("success")
        show(Banner(symbol: "arrow.triangle.2.circlepath",
                    text: first ? "\(plans.customPlanName ?? "Your home") arrived from \(state.macName)"
                                : "Updated from \(state.macName)"))
    }

    /// The answer to a `PlanChoice`.
    func resolvePlanChoice(keepPhone: Bool) {
        guard let choice = planChoice else { return }
        planChoice = nil
        if keepPhone {
            if let data = try? Data(contentsOf: plans.customPlanURL), sync.sendPlan(data) {
                show(Banner(symbol: "arrow.up.circle.fill", text: "Sent to \(choice.macName)"))
            } else {
                // Next time the Mac shows this plan unchanged, ours goes over.
                syncedRevision = PlanStore.revision(of: choice.macPlan)
                show(Banner(symbol: "exclamationmark.triangle.fill", text: "\(choice.macName) is not connected; it gets your plan next time",
                            tint: Theme.warm))
            }
        } else {
            adopt(SyncState(macName: choice.macName, revision: PlanStore.revision(of: choice.macPlan), plan: choice.macPlan,
                            userCode: suggestedUserCode, smartLifeConnected: false))
        }
    }

    // MARK: - Smart Life

    /// The User Code of the Smart Life account, for the Mac (empty without Smart Life).
    private var smartLifeUserCode: String {
        #if SMART_LIFE
        hub.smartLife?.userCode ?? ""
        #else
        ""
        #endif
    }

    #if SMART_LIFE
    /// Always there in the builds that include Smart Life.
    private var smartLife: SmartLifePlatform { hub.smartLife! }

    func beginLogin(userCode: String) async throws -> (token: String, qrContent: String) {
        try await smartLife.beginLogin(userCode: userCode)
    }

    /// True once the login was confirmed in the Smart Life app.
    func finishLogin(token: String, userCode: String) async -> Bool {
        guard await smartLife.finishLogin(token: token, userCode: userCode) else { return false }
        smartLifeConnected = smartLife.isSmartLifeConnected
        smartLifeAccount = smartLife.account
        sync.showQR(nil)
        sync.sendConnections(hub.shareableConnections, userCode: smartLifeUserCode)
        editorWeb?.call("servicesChanged", hub.servicesInfo)
        Haptics.shared.play("success")
        startPolling()
        return true
    }

    /// Asks the paired Mac to display the login code; false when it is not connected.
    func showOnMac(_ qrContent: String?) -> Bool { sync.showQR(qrContent) }

    func signOut() {
        smartLife.signOut()
        smartLifeConnected = false
        smartLifeAccount = ""
        pollTimer?.invalidate()
        pollTimer = nil
    }
    #endif

    // MARK: - Home Assistant, Hue, Apple Home

    func connectHomeAssistant(url: String, token: String) async throws {
        try await hub.connectHomeAssistant(url: url, token: token)
        connectionsChanged()
        Haptics.shared.play("success")
    }

    /// True once paired; false while nobody has pressed the bridge's button yet.
    func pairHue(host: String, bridgeId: String?, name: String?) async throws -> Bool {
        do {
            try await hub.pairHue(host: host, bridgeId: bridgeId, name: name)
        } catch is HueService.ButtonNotPressed {
            return false
        }
        connectionsChanged()
        Haptics.shared.play("success")
        return true
    }

    func disconnect(service: String) {
        hub.disconnect(service: service)
        connectionsChanged()
    }

    /// A platform was connected or disconnected here: read the devices again, tell the Mac.
    private func connectionsChanged() {
        refreshConnections()
        reloadLinks()
        startPolling()
        poll()
        sync.sendConnections(hub.shareableConnections, userCode: smartLifeUserCode)
        editorWeb?.call("servicesChanged", hub.servicesInfo)
    }

    var homeAssistantInfo: [String: Any] { hub.homeAssistant.info }

    /// True when at least one platform's devices can be linked.
    var hasAnyConnection: Bool {
        if case .ready = homeKit { return true }
        return smartLifeConnected || homeAssistantName != nil || hueName != nil
    }
    var hueInfo: [String: Any] { hub.hue.info }

    private func refreshConnections() {
        let ha = hub.homeAssistant.info
        homeAssistantName = ha["connected"] as? Bool == true ? (ha["name"] as? String ?? "Home Assistant") : nil
        let hue = hub.hue.info
        hueName = hue["connected"] as? Bool == true ? (hue["name"] as? String ?? "Hue Bridge") : nil
        let info = homeKitService.info
        if !homeKitService.isEnabled {
            homeKit = .off
        } else if homeKitService.isDenied {
            homeKit = .denied
        } else if info["connected"] as? Bool == true {
            homeKit = .ready(homes: info["homes"] as? [String] ?? [], accessories: info["accessories"] as? Int ?? 0)
        } else {
            homeKit = .waiting
        }
        linkedDevices = hub.linkedDeviceCount
    }

    /// Turns Apple Home on: iOS asks for permission the first time.
    func connectHomeKit() {
        homeKit = .waiting
        Task { @MainActor in
            await homeKitService.enable()
            refreshConnections()
            sendCatalog()
            startPolling()
            editorWeb?.call("servicesChanged", hub.servicesInfo)
            if case .ready = homeKit { Haptics.shared.play("success") }
        }
    }

    func disconnectHomeKit() {
        homeKitService.disconnect()
        sync.sendCatalog([])
        refreshConnections()
    }

    /// The Mac cannot see Apple Home, so this phone tells it what is there, for the editor.
    private func sendCatalog() {
        guard homeKitService.isConnected, sync.isPaired else { return }
        Task { @MainActor in
            guard let devices = try? await homeKitService.devices() else { return }
            sync.sendCatalog(devices.map { $0.dictionary(service: "homekit") })
        }
    }

    // MARK: - Welcome, banners

    enum WelcomeChoice { case setUpHere, pair, demo }

    func finishWelcome(_ choice: WelcomeChoice) {
        UserDefaults.standard.set(true, forKey: "welcomed")
        showWelcome = false
        guard choice != .demo else { return }
        if choice == .pair { settingsPath = [.pairing] }
        // One sheet has to be gone before the next can come up.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if choice == .pair { showSettings = true } else { showNewHome = true }
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
