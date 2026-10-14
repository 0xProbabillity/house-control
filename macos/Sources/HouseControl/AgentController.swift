import AppKit
import WebKit
import HouseCore

/// AI Access: a private link that lets an AI assistant (ChatGPT, Claude, an MCP client…)
/// see and run the home, served from this Mac.
///
///     AI ─HTTPS─▶ Cloudflare quick tunnel ─▶ cloudflared on this Mac ─▶ 127.0.0.1 gateway ─▶ the panel's store
///
/// Off until the user starts it. Every start makes a new secret link; Stop (or the auto-stop
/// timer) closes the gateway and the tunnel, and the old address stops existing.
@MainActor
final class AgentController: NSObject, AgentBackend {
    enum Reach: String { case internet, local }
    enum Phase: Equatable { case off, starting, live, failed(String) }

    let gateway = AgentGateway()
    private lazy var server = LoopbackHTTPServer { [unowned self] request in await self.gateway.handle(request) }
    private let tunnel: CloudflareTunnel
    private let plans: PlanStore
    /// The panel runs every request: it holds the state of each device.
    private let panel: () -> WebHost
    /// Reloads every view after the plan changed (and tells paired iPhones).
    private let reloadAll: () -> Void
    var onLiveChange: ((Bool) -> Void)?

    private(set) var phase: Phase = .off
    private var window: AgentWindow?
    private var activity: [AgentActivity] = []
    /// What the plan was before each change an AI made, newest last.
    private var history: [(data: Data?, active: String)] = []
    private var startedAt: Date?
    private var stopsAt: Date?
    private var stopTimer: Timer?
    private var tunnelError = ""

    private let defaults = UserDefaults.standard
    private var reach: Reach {
        // HOUSE_AGENT_REACH=local|internet overrides the saved choice for one run (tests).
        get { Reach(rawValue: ProcessInfo.processInfo.environment["HOUSE_AGENT_REACH"] ?? defaults.string(forKey: "agent.reach") ?? "") ?? .internet }
        set { defaults.set(newValue.rawValue, forKey: "agent.reach") }
    }
    /// "1h", "8h" or "never".
    private var autoStop: String {
        get { defaults.string(forKey: "agent.autoStop") ?? "8h" }
        set { defaults.set(newValue, forKey: "agent.autoStop") }
    }
    private var permissions: AgentPermissions {
        get { AgentPermissions(control: defaults.object(forKey: "agent.control") as? Bool ?? true,
                               edit: defaults.object(forKey: "agent.edit") as? Bool ?? true) }
        set {
            defaults.set(newValue.control, forKey: "agent.control")
            defaults.set(newValue.edit, forKey: "agent.edit")
            gateway.permissions = newValue
        }
    }

    init(plans: PlanStore, panel: @escaping () -> WebHost, reloadAll: @escaping () -> Void) {
        self.plans = plans
        self.panel = panel
        self.reloadAll = reloadAll
        tunnel = CloudflareTunnel(directory: plans.directory)
        super.init()
        gateway.backend = self
        gateway.permissions = permissions
        gateway.onActivity = { [weak self] entry in self?.log(entry) }
        tunnel.onChange = { [weak self] state in self?.tunnelChanged(state) }
    }

    var isLive: Bool { phase == .live }

    // MARK: - Start and stop

    func start() {
        switch phase {
        case .starting, .live: return
        default: break
        }
        if reach == .internet, tunnel.binary == nil {
            phase = .failed("needs-cloudflared")
            push()
            return
        }
        gateway.rotateToken()
        gateway.permissions = permissions
        phase = .starting
        tunnelError = ""
        push()
        server.start(preferredPort: 7419) { [weak self] result in
            guard let self, self.phase == .starting else { return }
            switch result {
            case .success(let port):
                if self.reach == .local {
                    self.gateway.publicBase = "http://127.0.0.1:\(port)"
                    self.goLive()
                } else {
                    self.tunnel.start(port: port)
                }
            case .failure(let error):
                self.fail("The local server could not start: \(error.localizedDescription)")
            }
        }
    }

    private func tunnelChanged(_ state: CloudflareTunnel.State) {
        switch state {
        case .live(let url):
            guard phase == .starting else { return }
            gateway.publicBase = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            goLive()
        case .failed(let message):
            guard phase == .starting || phase == .live else { return }
            fail(message)
        case .starting, .stopped:
            break
        }
    }

    private func goLive() {
        phase = .live
        startedAt = Date()
        scheduleAutoStop()
        log(AgentActivity(date: Date(), client: "House Control", title: reach == .local ? "Started on this Mac" : "Link is live", ok: true, quiet: false))
        onLiveChange?(true)
        push()
        // HOUSE_AGENT_LINK_FILE=<path> writes the live link there, for scripted tests.
        if let path = ProcessInfo.processInfo.environment["HOUSE_AGENT_LINK_FILE"] {
            try? gateway.linkURL.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func fail(_ message: String) {
        let wasLive = phase == .live
        tunnel.stop()
        server.stop()
        stopTimer?.invalidate()
        phase = .failed(message)
        if wasLive { onLiveChange?(false) }
        push()
    }

    func stop(reason: String = "Stopped") {
        guard phase != .off else { return }
        let wasLive = phase == .live
        tunnel.stop()
        server.stop()
        stopTimer?.invalidate()
        stopTimer = nil
        stopsAt = nil
        startedAt = nil
        phase = .off
        gateway.rotateToken() // the old link is dead even if the same address came back
        if wasLive {
            log(AgentActivity(date: Date(), client: "House Control", title: "\(reason) — the link no longer works", ok: true, quiet: false))
            onLiveChange?(false)
        }
        push()
    }

    private func scheduleAutoStop() {
        stopTimer?.invalidate()
        stopTimer = nil
        let hours: Double? = ["1h": 1, "8h": 8][autoStop]
        guard let hours, let startedAt else { stopsAt = nil; return }
        let when = startedAt.addingTimeInterval(hours * 3600)
        stopsAt = when
        stopTimer = Timer.scheduledTimer(withTimeInterval: max(1, when.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: "Stopped automatically") }
        }
    }

    private func log(_ entry: AgentActivity) {
        activity.append(entry)
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
        push()
    }

    // MARK: - Requests from the AI (AgentBackend)

    func agentRequest(_ request: [String: Any]) async throws -> [String: Any] {
        let host = try await readyPanel()
        let raw = try await host.webView.callAsyncJavaScript("return await window.house.agent(request)",
                                                             arguments: ["request": request], contentWorld: .page)
        guard let text = raw as? String, let data = text.data(using: .utf8),
              var result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError("House Control did not understand the request.")
        }
        if let plan = result["savePlan"] as? [String: Any] {
            result["savePlan"] = nil
            do {
                try savePlan(plan)
            } catch {
                result = ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true,
                          "summary": "Floor plan not saved: \(error.localizedDescription)"]
            }
        }
        if result["undo"] as? Bool == true {
            result["undo"] = nil
            do {
                try undo()
                result["content"] = [["type": "text", "text": "Undone: the floor plan is back to how it was before the last change. The 3D model is updating."]]
            } catch {
                result = ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true, "summary": error.localizedDescription]
            }
        }
        return result
    }

    /// The panel page, once it has (re)loaded: a request that arrives while the plan is
    /// being swapped waits for the new one.
    private func readyPanel() async throws -> WebHost {
        for _ in 0..<150 {
            let host = panel()
            if host.isReady { return host }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AgentError("House Control is busy loading the home. Try again in a moment.")
    }

    private func savePlan(_ plan: [String: Any]) throws {
        if plans.activePlan != "custom", plans.hasCustomPlan {
            throw AgentError("The user is looking at a demo plan, and their own home is saved separately. Ask them to switch to \"My home\" (gear menu in the panel) first.")
        }
        let previous = plans.hasCustomPlan ? try? Data(contentsOf: plans.customPlanURL) : nil
        let previousActive = plans.activePlan
        try plans.saveCustom(plan)
        history.append((previous, previousActive))
        if history.count > 30 { history.removeFirst() }
        reloadAll()
        push()
    }

    func undo() throws {
        guard let last = history.popLast() else { throw AgentError("There is no floor plan change to undo.") }
        if let data = last.data {
            try plans.saveCustom(data: data, select: true)
        } else {
            plans.removeCustom()
            plans.select(last.active)
        }
        reloadAll()
        log(AgentActivity(date: Date(), client: "House Control", title: "Undid the last floor plan change", ok: true, quiet: false))
    }

    struct AgentError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - Window

    func showWindow() {
        if window == nil {
            let host = WebHost(mode: "agent", transparent: false) { [unowned self] in ["agent": self.status()] }
            host.onMessage = { [weak self] message in self?.handle(message) }
            let window = AgentWindow(host: host)
            window.onClose = { [weak self, unowned host] in
                host.webView.configuration.userContentController.removeScriptMessageHandler(forName: "house")
                self?.window = nil
            }
            self.window = window
            host.load()
        }
        window?.show()
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "agent.start":
            if let r = (message["reach"] as? String).flatMap(Reach.init) { reach = r }
            start()
        case "agent.stop":
            stop()
        case "agent.settings":
            var p = permissions
            if let v = message["control"] as? Bool { p.control = v }
            if let v = message["edit"] as? Bool { p.edit = v }
            permissions = p
            if let v = message["autoStop"] as? String, ["1h", "8h", "never"].contains(v) {
                autoStop = v
                if phase == .live { scheduleAutoStop() }
            }
            if let r = (message["reach"] as? String).flatMap(Reach.init), phase != .live, phase != .starting { reach = r }
            push()
        case "agent.copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message["text"] as? String ?? "", forType: .string)
        case "agent.open":
            if let text = message["url"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
        case "agent.undo":
            do { try undo() } catch { log(AgentActivity(date: Date(), client: "House Control", title: error.localizedDescription, ok: false, quiet: false)) }
            push()
        case "agent.install":
            guard !tunnel.isDownloading else { return }
            Task { @MainActor in
                push()
                do {
                    try await tunnel.download()
                    if case .failed("needs-cloudflared") = phase { phase = .off }
                    push()
                } catch {
                    tunnelError = error.localizedDescription
                    push()
                }
            }
            DispatchQueue.main.async { [weak self] in self?.push() }
        case "ready":
            push()
        default:
            break
        }
    }

    func status() -> [String: Any] {
        var out: [String: Any] = [
            "reach": reach.rawValue,
            "autoStop": autoStop,
            "control": permissions.control,
            "edit": permissions.edit,
            "canUndo": !history.isEmpty,
            "activity": activity.suffix(80).map(\.json),
            "home": plans.activePlan == "custom" ? (plans.customPlanName ?? "My home") : "Demo home",
            "tunnel": ["installed": tunnel.binary != nil, "downloading": tunnel.isDownloading, "error": tunnelError],
        ]
        switch phase {
        case .off: out["state"] = "off"
        case .starting: out["state"] = "starting"
        case .live: out["state"] = "live"
        case .failed(let message):
            out["state"] = message == "needs-cloudflared" ? "setup" : "error"
            out["error"] = message
        }
        if phase == .live {
            out["link"] = gateway.linkURL
            out["mcp"] = gateway.mcpURL
            out["startedAt"] = (startedAt?.timeIntervalSince1970 ?? 0) * 1000
            if let stopsAt { out["stopsAt"] = stopsAt.timeIntervalSince1970 * 1000 }
        }
        return out
    }

    private func push() {
        window?.host.call("agentStatus", status())
    }
}

/// The AI Access window.
@MainActor
final class AgentWindow: NSObject, NSWindowDelegate {
    let host: WebHost
    private let window: NSWindow
    var onClose: (() -> Void)?

    init(host: WebHost) {
        self.host = host
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "AI Access"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.043, blue: 0.08, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 420, height: 560)
        window.maxSize = NSSize(width: 640, height: 2000)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = host.webView
        window.center()
        window.setFrameAutosaveName("HouseControlAgent")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
