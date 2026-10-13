import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let plans = PlanStore()
    private lazy var tuya = TuyaService(directory: plans.directory)
    private lazy var smartLife = SmartLifeService(directory: plans.directory)
    /// The backend real devices are reached through: the QR-linked Smart Life account
    /// when there is one, otherwise a Tuya Cloud project, otherwise nothing (simulation).
    private var cloud: DeviceCloud? {
        smartLife.isConfigured ? smartLife : (tuya.isConfigured ? tuya : nil)
    }
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var editor: EditorController?
    private var pollTimer: Timer?
    private lazy var log = EventLog(directory: plans.directory)
    /// App device id -> its Smart Life link, for the devices of the active plan.
    private var links: [String: (kind: String, link: [String: Any])] = [:]
    /// The command in flight for each real device; the next one waits for it.
    private var commandTails: [String: Task<Void, Never>] = [:]
    private let infrared = InfraredRemote()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

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
        reloadLinks()
        host.load()

        if ProcessInfo.processInfo.environment["HOUSE_OPEN_EDITOR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openEditor() }
        }
        if ProcessInfo.processInfo.environment["HOUSE_OPEN_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.togglePanel() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Status item

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "House Control")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        return image
    }

    private func updateStatus(_ summary: [String: Any]) {
        guard let button = statusItem.button else { return }
        let lights = summary["lightsOn"] as? Int ?? 0
        let acOn = summary["acOn"] as? Int ?? 0
        var parts: [String] = []
        if lights > 0 { parts.append("\(lights)") }
        if acOn > 0, let target = summary["acTarget"] as? Int { parts.append("\(target)°") }
        button.image = symbol(lights > 0 || acOn > 0 ? "house.fill" : "house")
        button.attributedTitle = NSAttributedString(
            string: parts.isEmpty ? "" : " " + parts.joined(separator: " · "),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)])
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
        boot["tuya"] = tuya.publicInfo
        boot["smartLife"] = smartLife.publicInfo
        if ProcessInfo.processInfo.environment["HOUSE_OPEN_EDITOR"] == "smartlife" { boot["section"] = "tuya" }
        // HOUSE_OPEN_DEVICE=<id> starts the panel on that light's or AC's detail sheet.
        if let device = ProcessInfo.processInfo.environment["HOUSE_OPEN_DEVICE"] { boot["openDevice"] = device }
        return boot
    }

    private func reloadLinks() {
        links = [:]
        guard plans.activePlan == "custom", let plan = plans.customPlan() else { return }
        for (kind, key) in [("light", "lights"), ("ac", "acs")] {
            for device in plan[key] as? [[String: Any]] ?? [] {
                guard let id = device["id"] as? String, let link = device["tuya"] as? [String: Any],
                      let deviceId = link["deviceId"] as? String, !deviceId.isEmpty else { continue }
                links[id] = (kind, link)
            }
        }
    }

    @objc private func reloadAll() {
        reloadLinks()
        panel.host.load()
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
        if !FileManager.default.fileExists(atPath: log.fileURL.path) { log.write("log started") }
        NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
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
            if let summary = (message["summary"] as? [String: Any]) ?? (message["lightsOn"] != nil ? message : nil) {
                updateStatus(summary)
            }
        case "command":
            forward(message, from: host)
        case "close":
            panel.hide()
        case "selectPlan":
            if let plan = message["plan"] as? String {
                plans.select(plan)
                reloadAll()
                editor?.host.load()
            }
        case "loadPlan": loadPlan()
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
            let secret = message["accessSecret"] as? String ?? ""
            let credentials = TuyaService.Credentials(
                accessId: (message["accessId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                // An empty secret field means "keep the one already stored".
                accessSecret: secret.isEmpty ? (tuya.credentials?.accessSecret ?? "") : secret.trimmingCharacters(in: .whitespacesAndNewlines),
                region: message["region"] as? String ?? "eu")
            do {
                try tuya.save(credentials.accessId.isEmpty ? nil : credentials)
                host.reply(to: message, tuya.publicInfo)
            } catch {
                host.reply(to: message, ["error": error.localizedDescription])
            }
        case "tuya.devices":
            Task { @MainActor in
                do {
                    guard let cloud else { throw SmartLifeService.Failure(message: "Connect Smart Life first") }
                    host.reply(to: message, ["devices": try await cloud.listDevices()])
                } catch {
                    host.reply(to: message, ["error": error.localizedDescription])
                }
            }
        case "smartlife.begin":
            let userCode = message["userCode"] as? String ?? ""
            Task { @MainActor in
                do {
                    let login = try await smartLife.beginLogin(userCode: userCode)
                    host.reply(to: message, ["token": login.token,
                                             "qr": SmartLifeService.qrImageDataURL(for: login.qrContent) ?? ""])
                } catch {
                    host.reply(to: message, ["error": error.localizedDescription])
                }
            }
        case "smartlife.poll":
            let token = message["token"] as? String ?? ""
            let userCode = message["userCode"] as? String ?? ""
            Task { @MainActor in
                let done = (try? await smartLife.finishLogin(token: token, userCode: userCode)) ?? false
                host.reply(to: message, ["connected": done, "info": smartLife.publicInfo])
            }
        case "smartlife.signOut":
            smartLife.signOut()
            host.reply(to: message, smartLife.publicInfo)
        default:
            break
        }
    }

    // MARK: - Smart Life

    /// Sends a change made in the panel to the real device and tells the panel how it went,
    /// so a rejected change can be rolled back there. Commands to one device run strictly
    /// one after another.
    private func forward(_ message: [String: Any], from host: WebHost) {
        guard let cloud, let id = message["id"] as? String, let entry = links[id],
              let deviceId = entry.link["deviceId"] as? String else {
            host.reply(to: message, ["ok": true]) // simulated device: nothing to send
            return
        }
        let patch = message["patch"] as? [String: Any] ?? [:]
        let state = message["state"] as? [String: Any] ?? [:]
        let previous = commandTails[deviceId]
        commandTails[deviceId] = Task { @MainActor in
            await previous?.value
            do {
                // The first command to a device may arrive before anything is known about it.
                await cloud.prepare(deviceId)
                let codes = cloud.knownCodes[deviceId] ?? []
                if entry.kind == "light" {
                    try await send(TuyaMapper.lightCommands(patch: patch, state: state, link: entry.link, codes: codes,
                                                            ranges: cloud.knownRanges[deviceId] ?? [:]), to: deviceId, id, cloud)
                } else if TuyaMapper.isInfraredAC(codes) {
                    try await infrared.apply(patch: patch, state: state, to: deviceId,
                                             send: { try await self.send([$0], to: deviceId, id, cloud) },
                                             note: { self.log.write("\(id) \($0)") })
                } else {
                    try await send(TuyaMapper.acCommands(patch: patch, link: entry.link, codes: codes), to: deviceId, id, cloud)
                }
                host.reply(to: message, ["ok": true])
            } catch let rejected as InfraredRemote.Rejection {
                host.reply(to: message, ["error": rejected.message, "failed": rejected.fields])
            } catch {
                host.reply(to: message, ["error": error.localizedDescription])
                // The panel showed the change optimistically: pull the real state back in.
                poll()
            }
        }
    }

    private func send(_ commands: [[String: Any]], to deviceId: String, _ id: String, _ cloud: DeviceCloud) async throws {
        guard !commands.isEmpty else { return }
        do {
            try await cloud.send(commands, to: deviceId)
            log.write("\(id) \(EventLog.describe(commands)) → ok")
        } catch {
            log.write("\(id) \(EventLog.describe(commands)) → \(error.localizedDescription)")
            throw error
        }
    }

    private func setPolling(_ on: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard on, cloud != nil, !links.isEmpty else { return }
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let entries = links
        guard let cloud else { return }
        Task { @MainActor in
            // Devices plus the temperature sensors that stand in for an AC's room reading.
            let ids = entries.values.flatMap { [$0.link["deviceId"] as? String, $0.link["sensorId"] as? String].compactMap { $0 } }
            guard let status = try? await cloud.status(of: Array(Set(ids)).filter { !$0.isEmpty }) else { return }
            var lights: [String: Any] = [:]
            var acs: [String: Any] = [:]
            var features: [String: Any] = [:]
            for (id, entry) in entries {
                guard let deviceId = entry.link["deviceId"] as? String else { continue }
                if entry.kind == "ac", let known = TuyaMapper.acFeatures(codes: cloud.knownCodes[deviceId] ?? [],
                                                                         ranges: cloud.knownRanges[deviceId] ?? [:]) {
                    features[id] = known
                }
                if entry.kind == "light" {
                    if let dps = status[deviceId] {
                        lights[id] = TuyaMapper.lightState(from: dps, ranges: cloud.knownRanges[deviceId] ?? [:])
                    }
                    continue
                }
                var state = status[deviceId].map { TuyaMapper.acState(from: $0) } ?? [:]
                if let sensorId = entry.link["sensorId"] as? String, let dps = status[sensorId],
                   let temperature = TuyaMapper.sensorTemperature(from: dps) {
                    state["roomTemp"] = temperature
                }
                if !state.isEmpty { acs[id] = state }
            }
            panel.host.call("applyRemote", ["lights": lights, "acs": acs, "features": features])
        }
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
