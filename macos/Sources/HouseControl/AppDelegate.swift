import AppKit
import UniformTypeIdentifiers
import HouseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let plans = PlanStore()
    /// The Smart Life / Tuya side: device links, commands and state.
    private lazy var hub = DeviceHub(directory: plans.directory)
    /// Hands the floor plan to paired iPhones on the local network.
    private lazy var sync = SyncServer(store: FileSecretStore(url: plans.directory.appendingPathComponent("sync.json")))
    private var island: IslandController?
    private var pairingWindow: QRWindowController?
    private var loginWindow: QRWindowController?
    private var loginWindowExpiry: DispatchWorkItem?
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var editor: EditorController?
    private var pollTimer: Timer?
    /// AI Access: the private link an AI assistant uses to run the home.
    private lazy var agent: AgentController = {
        let agent = AgentController(plans: plans, panel: { [unowned self] in self.panel.host }, reloadAll: { [unowned self] in
            self.reloadAll()
            self.editor?.host.load()
        })
        agent.onLiveChange = { [weak self] live in
            guard let self else { return }
            self.panel.host.call("agentLive", live)
            self.refreshStatusIcon()
        }
        return agent
    }()
    private var lastSummary: [String: Any] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        stopTunnelOnSignals()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = symbol("house.fill")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "House Control"
        }

        let host = WebHost(mode: "panel", transparent: true) { [unowned self] in self.bootPayload() }
        host.onMessage = { [weak self, unowned host] message in self?.handle(message, from: host) }
        panel = PanelController(host: host)
        panel.onVisibilityChange = { [weak self] visible in self?.setPolling(visible) }
        hub.onStale = { [weak self] in self?.poll() }
        reloadLinks()
        host.load()
        startSync()
        if islandEnabled { showIsland() }

        // HOUSE_SNAPSHOT_DIR=<folder> writes panel.png and island.png there a few seconds
        // after launch: a look at the UI without a screen (see HOUSE_RENDER_HIDDEN).
        if let folder = ProcessInfo.processInfo.environment["HOUSE_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            let delay = Double(ProcessInfo.processInfo.environment["HOUSE_SNAPSHOT_DELAY"] ?? "") ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.panel.host.snapshot(to: directory.appendingPathComponent("panel.png"))
                self?.island?.host.snapshot(to: directory.appendingPathComponent("island.png"))
            }
        }
        if ProcessInfo.processInfo.environment["HOUSE_OPEN_PAIRING"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.pairPhone() }
        }
        if ProcessInfo.processInfo.environment["HOUSE_OPEN_EDITOR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openEditor() }
        }
        if let open = ProcessInfo.processInfo.environment["HOUSE_OPEN_AGENT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openAgent()
                if open == "start" { self?.agent.start() }
            }
        }
        if ProcessInfo.processInfo.environment["HOUSE_OPEN_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.togglePanel() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        agent.stop(reason: "House Control quit")
    }

    /// `kill`, a logout or Ctrl-C end the app without applicationWillTerminate: the AI
    /// Access tunnel must not outlive it.
    private var signalSources: [DispatchSourceSignal] = []
    private func stopTunnelOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.agent.stop(reason: "House Control quit") }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Status item

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "House Control")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        return image
    }

    private func updateStatus(_ summary: [String: Any]) {
        lastSummary = summary
        refreshStatusIcon()
    }

    /// The house, with sparkles beside it while an AI assistant has a live link.
    private func refreshStatusIcon() {
        guard let button = statusItem.button else { return }
        let summary = lastSummary
        let lights = summary["lightsOn"] as? Int ?? 0
        let acOn = summary["acOn"] as? Int ?? 0
        var parts: [String] = []
        if lights > 0 { parts.append("\(lights)") }
        if acOn > 0, let target = summary["acTarget"] as? Int { parts.append("\(target)°") }
        let house = lights > 0 || acOn > 0 ? "house.fill" : "house"
        button.image = agent.isLive ? pair(house, "sparkles") : symbol(house)
        button.attributedTitle = NSAttributedString(
            string: parts.isEmpty ? "" : " " + parts.joined(separator: " · "),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)])
    }

    /// Two symbols side by side as one template image.
    private func pair(_ first: String, _ second: String) -> NSImage? {
        guard let a = symbol(first), let b = NSImage(systemSymbolName: second, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)) else { return symbol(first) }
        let size = NSSize(width: a.size.width + b.size.width + 1, height: max(a.size.height, b.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            a.draw(in: NSRect(x: 0, y: (size.height - a.size.height) / 2, width: a.size.width, height: a.size.height))
            b.draw(in: NSRect(x: a.size.width + 1, y: size.height - b.size.height, width: b.size.width, height: b.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel.hide()
            let menu = NSMenu()
            menu.addItem(withTitle: "Edit Home…", action: #selector(openEditor), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Load Floor Plan…", action: #selector(loadPlan), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Reveal Plan File", action: #selector(revealPlan), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Reveal Device Log", action: #selector(revealLog), keyEquivalent: "").target = self
            menu.addItem(.separator())
            let islandItem = menu.addItem(withTitle: "Show Island", action: #selector(toggleIsland), keyEquivalent: "")
            islandItem.target = self
            islandItem.state = island?.isShown == true ? .on : .off
            menu.addItem(withTitle: "Pair iPhone…", action: #selector(pairPhone), keyEquivalent: "").target = self
            let aiItem = menu.addItem(withTitle: agent.isLive ? "AI Access — Live" : "AI Access…", action: #selector(openAgent), keyEquivalent: "")
            aiItem.target = self
            aiItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            if agent.isLive {
                menu.addItem(withTitle: "Stop AI Access", action: #selector(stopAgent), keyEquivalent: "").target = self
            }
            for device in sync.connectedDevices {
                let item = menu.addItem(withTitle: "\(device) is connected", action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Reload", action: #selector(reloadAll), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Quit House Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        togglePanel()
    }

    private func togglePanel() {
        guard let button = statusItem.button else { return }
        panel.toggle(below: button)
    }

    // MARK: - Plans

    private func bootPayload() -> [String: Any] {
        var boot = plans.bootPayload()
        boot["tuya"] = hub.tuyaInfo
        boot["smartLife"] = hub.smartLifeInfo
        boot["services"] = hub.servicesInfo
        switch ProcessInfo.processInfo.environment["HOUSE_OPEN_EDITOR"] {
        case "smartlife": boot["section"] = "service:smartlife"
        case "homeassistant", "hue", "homekit", "connections":
            let section = ProcessInfo.processInfo.environment["HOUSE_OPEN_EDITOR"]!
            boot["section"] = section == "connections" ? "connections" : "service:\(section)"
        default: break
        }
        boot["agentLive"] = agent.isLive
        // HOUSE_OPEN_DEVICE=<id> starts the panel on that light's or AC's detail sheet.
        if let device = ProcessInfo.processInfo.environment["HOUSE_OPEN_DEVICE"] { boot["openDevice"] = device }
        return boot
    }

    private func reloadLinks() {
        hub.setLinks(from: plans.activePlan == "custom" ? plans.customPlan() : nil)
    }

    /// A platform was connected or disconnected: read the devices again and tell the phones.
    private func connectionsChanged() {
        reloadLinks()
        setPolling(false) // reads at once while the panel or the island is open
        sync.broadcast()
    }

    @objc private func reloadAll() {
        reloadLinks()
        panel.host.load()
        if island?.isShown == true { island?.host.load() }
        sync.broadcast()
    }

    @objc private func loadPlan() {
        panel.hide()
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.title = "Choose a floor plan"
        open.allowedContentTypes = [.json]
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            try plans.importPlan(from: url)
            reloadAll()
            editor?.host.load()
        } catch {
            alert("Could not load this floor plan", error.localizedDescription)
        }
    }

    @objc private func revealPlan() {
        let url = plans.hasCustomPlan ? plans.customPlanURL : WebHost.assetRoot.appendingPathComponent("plans/\(plans.activePlan).json")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func revealLog() {
        if !FileManager.default.fileExists(atPath: hub.log.fileURL.path) { hub.log.write("log started") }
        NSWorkspace.shared.activateFileViewerSelecting([hub.log.fileURL])
    }

    @objc private func openEditor() {
        panel.hide()
        if editor == nil {
            let host = WebHost(mode: "editor", transparent: false) { [unowned self] in self.bootPayload() }
            host.onMessage = { [weak self, unowned host] message in self?.handle(message, from: host) }
            let controller = EditorController(host: host)
            controller.onClose = { [weak self, unowned host] in
                host.webView.configuration.userContentController.removeScriptMessageHandler(forName: "house")
                self?.editor = nil
            }
            editor = controller
            host.load()
        }
        editor?.show()
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: - Messages from the web UI

    private func handle(_ message: [String: Any], from host: WebHost) {
        switch message["type"] as? String {
        case "ready", "summary":
            // A view that has just loaded takes over what the panel shows.
            if message["type"] as? String == "ready", host !== panel.host { panel.host.call("share") }
            if let summary = (message["summary"] as? [String: Any]) ?? (message["lightsOn"] != nil ? message : nil) {
                updateStatus(summary)
            }
        case "state":
            // The panel and the island are two views of one home: what changes in one is
            // shown by the other.
            var state = message
            state["type"] = nil
            for other in [panel.host, island?.host] where other !== host { other?.call("adopt", state) }
        case "command":
            hub.command(message) { [weak host] in host?.reply(to: message, $0) }
        case "close":
            panel.hide()
        case "selectPlan":
            if let plan = message["plan"] as? String {
                plans.select(plan)
                reloadAll()
                editor?.host.load()
            }
        case "loadPlan": loadPlan()
        case "openAgent": openAgent()
        case "revealPlan": revealPlan()
        case "openEditor": openEditor()
        case "quit": NSApp.terminate(nil)

        // Editor
        case "savePlan":
            guard let config = message["config"] as? [String: Any] else { return }
            do {
                try plans.saveCustom(config)
                reloadAll()
                host.reply(to: message, ["ok": true, "path": plans.customPlanURL.path])
            } catch {
                host.reply(to: message, ["error": error.localizedDescription])
            }
        case "importPlan":
            let open = NSOpenPanel()
            open.allowedContentTypes = [.json]
            guard open.runModal() == .OK, let url = open.url,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                host.reply(to: message, ["cancelled": true])
                return
            }
            host.reply(to: message, ["config": json])
        case "exportPlan":
            guard let config = message["config"] as? [String: Any] else { return }
            let save = NSSavePanel()
            save.allowedContentTypes = [.json]
            save.nameFieldStringValue = "\((config["name"] as? String ?? "home").lowercased()).json"
            guard save.runModal() == .OK, let url = save.url else {
                host.reply(to: message, ["cancelled": true])
                return
            }
            do {
                try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url)
                host.reply(to: message, ["ok": true])
            } catch {
                host.reply(to: message, ["error": error.localizedDescription])
            }
        case "tuya.save":
            do {
                try hub.saveTuya(accessId: message["accessId"] as? String ?? "",
                                 accessSecret: message["accessSecret"] as? String ?? "",
                                 region: message["region"] as? String ?? "eu")
                host.reply(to: message, hub.tuyaInfo)
            } catch {
                host.reply(to: message, ["error": error.localizedDescription])
            }
        case "tuya.devices":
            Task { @MainActor in
                do {
                    host.reply(to: message, ["devices": try await hub.listDevices()])
                } catch {
                    host.reply(to: message, ["error": error.localizedDescription])
                }
            }
        case "smartlife.begin":
            let userCode = message["userCode"] as? String ?? ""
            Task { @MainActor in
                do {
                    let login = try await hub.beginLogin(userCode: userCode)
                    let png = QRCode.png(for: login.qrContent).map { "data:image/png;base64,\($0.base64EncodedString())" }
                    host.reply(to: message, ["token": login.token, "qr": png ?? ""])
                } catch {
                    host.reply(to: message, ["error": error.localizedDescription])
                }
            }
        case "smartlife.poll":
            let token = message["token"] as? String ?? ""
            let userCode = message["userCode"] as? String ?? ""
            Task { @MainActor in
                let done = await hub.finishLogin(token: token, userCode: userCode)
                host.reply(to: message, ["connected": done, "info": hub.smartLifeInfo])
                if done { sync.broadcast() }
            }
        case "smartlife.signOut":
            hub.signOut()
            host.reply(to: message, hub.smartLifeInfo)
            sync.broadcast()

        // Home Assistant, Philips Hue, Apple Home
        case "services.info":
            host.reply(to: message, hub.servicesInfo)
        case "devices.all":
            Task { @MainActor in
                let (devices, errors) = await hub.allDevices()
                host.reply(to: message, ["devices": devices, "errors": errors])
            }
        case "services.discover":
            let service = message["service"] as? String ?? ""
            Task { @MainActor in
                let found = service == "hue" ? await ServiceDiscovery.hueBridges() : await ServiceDiscovery.homeAssistants()
                host.reply(to: message, ["found": found])
            }
        case "homeassistant.connect":
            Task { @MainActor in
                do {
                    try await hub.homeAssistant.connect(url: message["url"] as? String ?? "", token: message["token"] as? String ?? "")
                    connectionsChanged()
                    host.reply(to: message, hub.servicesInfo)
                } catch {
                    host.reply(to: message, ["error": error.localizedDescription])
                }
            }
        case "hue.pair":
            Task { @MainActor in
                do {
                    try await hub.hue.pair(host: message["host"] as? String ?? "", bridgeId: message["bridgeId"] as? String,
                                           name: message["name"] as? String)
                    connectionsChanged()
                    host.reply(to: message, hub.servicesInfo)
                } catch is HueService.ButtonNotPressed {
                    host.reply(to: message, ["waiting": true])
                } catch {
                    host.reply(to: message, ["error": error.localizedDescription])
                }
            }
        case "service.disconnect":
            hub.services.first { $0.id == message["service"] as? String }?.disconnect()
            connectionsChanged()
            host.reply(to: message, hub.servicesInfo)
        default:
            break
        }
    }

    // MARK: - AI Access

    @objc private func openAgent() {
        panel.hide()
        agent.showWindow()
    }

    @objc private func stopAgent() { agent.stop() }

    // MARK: - Device state

    /// Real devices are read while there is something on screen to show them in.
    private func setPolling(_ requested: Bool) {
        let on = requested || panel.isVisible || island?.isExpanded == true
        pollTimer?.invalidate()
        pollTimer = nil
        guard on, hub.canPoll else { return }
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        Task { @MainActor in
            guard let update = await hub.poll() else { return }
            panel.host.call("applyRemote", update) // the island adopts it from the panel
        }
    }

    // MARK: - Island

    /// On unless switched off in the menu (or by HOUSE_ISLAND=0 for one run).
    private var islandEnabled: Bool {
        if let forced = ProcessInfo.processInfo.environment["HOUSE_ISLAND"] { return forced != "0" }
        return UserDefaults.standard.object(forKey: "island") as? Bool ?? true
    }

    private func showIsland() {
        if island == nil {
            let host = WebHost(mode: "island", transparent: true) { [unowned self] in
                var boot = self.plans.bootPayload()
                boot["island"] = self.island?.bootInfo ?? [:]
                return boot
            }
            host.onMessage = { [weak self, unowned host] message in self?.handle(message, from: host) }
            let controller = IslandController(host: host)
            controller.onExpandedChange = { [weak self] open in self?.setPolling(open) }
            island = controller
        }
        island?.show()
    }

    @objc private func toggleIsland() {
        let show = island?.isShown != true
        UserDefaults.standard.set(show, forKey: "island")
        if show { showIsland() } else { island?.hide() }
    }

    // MARK: - iPhone sync

    /// The name paired iPhones see (HOUSE_COMPUTER_NAME replaces it for screenshots).
    private var computerName: String {
        ProcessInfo.processInfo.environment["HOUSE_COMPUTER_NAME"] ?? Host.current().localizedName ?? "Mac"
    }

    private func startSync() {
        sync.snapshot = { [unowned self] in
            SyncState(macName: self.computerName,
                      revision: self.plans.customPlanRevision ?? "",
                      plan: try? Data(contentsOf: self.plans.customPlanURL),
                      userCode: self.hub.smartLifeUserCode,
                      smartLifeConnected: self.hub.isSmartLifeConnected,
                      connections: self.hub.shareableConnections)
        }
        sync.onCatalog = { [weak self] devices, phone in
            guard let self, let catalog = self.hub.homeKit as? RemoteCatalogService else { return }
            catalog.update(devices: devices, from: phone)
            self.editor?.host.call("servicesChanged", self.hub.servicesInfo)
        }
        sync.onPeersChanged = { [weak self] in self?.refreshPairingWindow() }
        sync.onShowQR = { [weak self] content, device in self?.showLoginCode(content, for: device) }
        sync.start() // only listens once a phone has been paired
    }

    /// Shows the QR code an iPhone scans once to find this Mac and receive its floor plan.
    @objc private func pairPhone() {
        panel.hide()
        let pairing = sync.enable(name: computerName)
        if pairingWindow == nil {
            let window = QRWindowController(title: "Pair iPhone")
            window.onClose = { [weak self] in self?.pairingWindow = nil }
            window.addButton("Copy Pairing Link") { [weak self] in
                guard let link = self?.sync.pairing?.link else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }
            window.addButton("Reset Pairing…") { [weak self] in self?.resetPairing() }
            pairingWindow = window
        }
        pairingWindow?.show(code: pairing.link,
                            headline: "Scan with House Control on your iPhone",
                            detail: "On the iPhone open Settings → Pair with Mac. Both devices must be on the same Wi-Fi. "
                                + "Your floor plan is sent straight from this Mac to the phone, encrypted with the key in this code.")
        refreshPairingWindow()
    }

    private func resetPairing() {
        let alert = NSAlert()
        alert.messageText = "Reset pairing?"
        alert.informativeText = "Every iPhone paired so far stops syncing until it scans the new code."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        sync.reset(name: computerName)
        pairPhone()
    }

    private func refreshPairingWindow() {
        let devices = sync.connectedDevices
        if !devices.isEmpty {
            pairingWindow?.setStatus("Connected: \(devices.joined(separator: ", "))", active: true)
        } else if sync.isAdvertised {
            pairingWindow?.setStatus("Waiting for an iPhone…", active: false)
        } else {
            // Until macOS lets the app use the local network, no phone can find this Mac.
            pairingWindow?.setStatus("Allow Local Network access for House Control in System Settings → Privacy & Security",
                                     active: false)
        }
    }

    /// A paired iPhone signs in to Smart Life on its own, but its login code has to be
    /// scanned by the Smart Life app on that same phone, so it borrows this Mac's screen.
    ///
    /// The window does not follow the phone's connection: to scan the code the user switches
    /// to Smart Life, our app goes to the background and iOS disconnects it. It closes when
    /// the phone says it is signed in (or gave up), when the user closes it, or after ten
    /// minutes, by which time the login ticket is long dead.
    private func showLoginCode(_ content: String?, for device: String) {
        loginWindowExpiry?.cancel()
        loginWindowExpiry = nil
        guard let content, content.hasPrefix("tuyaSmart--qrLogin?token=") else {
            loginWindow?.close()
            loginWindow = nil
            return
        }
        let expiry = DispatchWorkItem { [weak self] in
            self?.loginWindow?.close()
            self?.loginWindow = nil
        }
        loginWindowExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: expiry)
        if loginWindow == nil {
            let window = QRWindowController(title: "Smart Life Sign-In for \(device)")
            window.onClose = { [weak self] in self?.loginWindow = nil }
            loginWindow = window
        }
        loginWindow?.show(code: content,
                          headline: "Scan with the Smart Life app on \(device)",
                          detail: "Switch to Smart Life on the iPhone, tap the scanner on its Home tab and confirm the login. "
                              + "Then return to House Control: this window closes once the iPhone is signed in.")
        loginWindow?.setStatus("Requested by \(device)", active: true)
    }

    // MARK: - Menu (gives the editor window the usual shortcuts)

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit House Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
