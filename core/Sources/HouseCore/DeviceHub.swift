import Foundation

/// Everything between the UI and the real devices, shared by the Mac and the iPhone app:
/// which platforms are connected (Smart Life, Home Assistant, Philips Hue, Apple Home),
/// which device of the plan is linked to which real device, sending the changes made in
/// the panel and reading the devices' state back.
@MainActor
public final class DeviceHub {
    public let log: EventLog
    private let tuya: TuyaService
    private let smartLife: SmartLifeService
    public let homeAssistant: HomeAssistantService
    public let hue: HueService
    /// Apple Home: HomeKit itself on the iPhone, the iPhone's catalog on the Mac.
    public let homeKit: DeviceService
    /// The platforms other than Smart Life, by the id a plan's `link.service` uses.
    public var services: [DeviceService] { [homeAssistant, hue, homeKit] }
    private func service(_ id: String) -> DeviceService? { services.first { $0.id == id } }
    /// The backend real devices are reached through: the QR-linked Smart Life account
    /// when there is one, otherwise a Tuya Cloud project, otherwise nothing (simulation).
    private var cloud: DeviceCloud? {
        smartLife.isConfigured ? smartLife : (tuya.isConfigured ? tuya : nil)
    }
    /// App device id -> its Smart Life link, for the devices of the active plan.
    private var links: [String: (kind: String, link: [String: Any])] = [:]
    /// App device id -> its link to another platform.
    private struct Link {
        var kind: DeviceKind
        var service: String
        var id: String
        /// A temperature sensor for an AC's room reading, on any platform.
        var sensor: (service: String, id: String)?
    }
    private var serviceLinks: [String: Link] = [:]
    /// Sensors from other platforms that report the room of a Smart Life AC.
    private var tuyaSensors: [String: (service: String, id: String)] = [:]
    private var refresh: Task<Void, Never>?
    /// The command in flight for each real device; the next one waits for it.
    private var commandTails: [String: Task<Void, Never>] = [:]
    private let infrared = InfraredRemote()

    /// Called after a command failed in a way that leaves the panel out of step with the
    /// devices, so the owner can read their state again.
    public var onStale: (() -> Void)?

    /// `secret(name)` is where a platform's credentials are kept ("smartlife", "homeassistant",
    /// "hue"); by default `<name>.json` in `directory`, readable by its user only. `homeKit`
    /// is HomeKit on the iPhone; without one, Apple Home is the catalog a paired iPhone sent.
    public init(directory: URL, secret: ((String) -> SecretStore)? = nil, homeKit: DeviceService? = nil) {
        let vault = secret ?? { FileSecretStore(url: directory.appendingPathComponent("\($0).json")) }
        log = EventLog(directory: directory)
        stampsURL = directory.appendingPathComponent("connections-sync.json")
        tuya = TuyaService(directory: directory)
        smartLife = SmartLifeService(vault: vault("smartlife"))
        homeAssistant = HomeAssistantService(vault: vault("homeassistant"))
        hue = HueService(vault: vault("hue"))
        self.homeKit = homeKit ?? RemoteCatalogService(id: "homekit", title: "Apple Home",
                                                       file: directory.appendingPathComponent("homekit-devices.json"))
        for service in services {
            service.onChange = { [weak self] in self?.scheduleRefresh() }
        }
    }

    /// Changes reported by a platform arrive in bursts: one read for all of them.
    private func scheduleRefresh() {
        refresh?.cancel()
        refresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.onStale?()
        }
    }

    // MARK: - Links

    public var isConnected: Bool { cloud != nil || services.contains { $0.isConnected && $0.controlsDevices } }
    public var hasLinks: Bool { !links.isEmpty || !serviceLinks.isEmpty }
    /// True when there is something to read at all.
    public var canPoll: Bool {
        (cloud != nil && !links.isEmpty)
            || serviceLinks.values.contains { service($0.service).map { $0.isConnected && $0.controlsDevices } ?? false }
    }
    public var linkedDeviceCount: Int { links.count + serviceLinks.values.filter { !$0.id.isEmpty }.count }

    /// Takes the device links from `plan`; nil (a bundled demo) means everything is simulated.
    public func setLinks(from plan: [String: Any]?) {
        links = [:]
        serviceLinks = [:]
        tuyaSensors = [:]
        defer { watchLinks() }
        guard let plan else { return }
        for (kind, key) in [("light", "lights"), ("ac", "acs")] {
            for device in plan[key] as? [[String: Any]] ?? [] {
                guard let id = device["id"] as? String else { continue }
                let sensor = Self.sensorLink(device["sensor"])
                if let link = device["link"] as? [String: Any], let service = link["service"] as? String,
                   let target = link["id"] as? String, !target.isEmpty {
                    serviceLinks[id] = Link(kind: DeviceKind(rawValue: kind) ?? .light, service: service, id: target, sensor: sensor)
                } else if let link = device["tuya"] as? [String: Any], let deviceId = link["deviceId"] as? String, !deviceId.isEmpty {
                    links[id] = (kind, link)
                    if let sensor { tuyaSensors[id] = sensor }
                } else if let sensor, kind == "ac" {
                    // A simulated AC can still show a real room temperature.
                    serviceLinks[id] = Link(kind: .ac, service: "", id: "", sensor: sensor)
                }
            }
        }
    }

    /// `{"service": "hue", "id": "…"}` in a plan.
    private static func sensorLink(_ value: Any?) -> (service: String, id: String)? {
        guard let sensor = value as? [String: Any], let service = sensor["service"] as? String,
              let id = sensor["id"] as? String, !id.isEmpty else { return nil }
        return (service, id)
    }

    /// Tells each platform which of its devices the plan uses, for its live updates.
    private func watchLinks() {
        var ids: [String: Set<String>] = [:]
        for link in serviceLinks.values {
            if !link.id.isEmpty { ids[link.service, default: []].insert(link.id) }
            if let sensor = link.sensor { ids[sensor.service, default: []].insert(sensor.id) }
        }
        for sensor in tuyaSensors.values { ids[sensor.service, default: []].insert(sensor.id) }
        for service in services { service.watch(ids[service.id] ?? []) }
    }

    // MARK: - Commands

    /// Sends a change made in the panel to the real device and tells the panel how it went,
    /// so a rejected change can be rolled back there. Commands to one device run strictly
    /// one after another, in the order this is called.
    public func command(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        if let id = message["id"] as? String, let link = serviceLinks[id], !link.id.isEmpty {
            commandService(link, appId: id, message, reply: reply)
            return
        }
        guard let cloud, let id = message["id"] as? String, let entry = links[id],
              let deviceId = entry.link["deviceId"] as? String else {
            reply(["ok": true]) // simulated device: nothing to send
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
                reply(["ok": true])
            } catch let rejected as InfraredRemote.Rejection {
                reply(["error": rejected.message, "failed": rejected.fields])
            } catch {
                reply(["error": error.localizedDescription])
                // The panel showed the change optimistically: pull the real state back in.
                onStale?()
            }
        }
    }

    private func commandService(_ link: Link, appId: String, _ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let service = service(link.service), service.isConnected, service.controlsDevices else {
            reply(["ok": true]) // not reachable from here (Apple Home on the Mac): simulated
            return
        }
        let patch = message["patch"] as? [String: Any] ?? [:]
        let state = message["state"] as? [String: Any] ?? [:]
        let key = "\(link.service):\(link.id)"
        let previous = commandTails[key]
        commandTails[key] = Task { @MainActor in
            await previous?.value
            let what = patch.keys.sorted().map { "\($0)=\(patch[$0] ?? "")" }.joined(separator: " ")
            do {
                try await service.send(kind: link.kind, id: link.id, patch: patch, state: state)
                log.write("\(appId) [\(service.title)] \(what) → ok")
                reply(["ok": true])
            } catch {
                log.write("\(appId) [\(service.title)] \(what) → \(error.localizedDescription)")
                reply(["error": error.localizedDescription])
                onStale?()
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

    // MARK: - State

    /// What the linked devices report right now, in the shape the panel's `applyRemote`
    /// takes. Nil when nothing is connected or the cloud could not be reached.
    public func poll() async -> [String: Any]? {
        async let tuyaPart = pollSmartLife()
        async let servicePart = pollServices()
        let (fromTuya, fromServices) = await (tuyaPart, servicePart)
        guard fromTuya != nil || fromServices != nil else { return nil }
        var merged: [String: Any] = [:]
        for key in ["lights", "acs", "features"] {
            var section = fromTuya?[key] as? [String: Any] ?? [:]
            for (id, value) in fromServices?[key] as? [String: Any] ?? [:] {
                if var existing = section[id] as? [String: Any], let more = value as? [String: Any] {
                    existing.merge(more) { $1 }
                    section[id] = existing
                } else {
                    section[id] = value
                }
            }
            merged[key] = section
        }
        return merged
    }

    /// Home Assistant, Hue and Apple Home, each asked once for all of its linked devices.
    private func pollServices() async -> [String: Any]? {
        var wanted: [String: Set<String>] = [:]
        for link in serviceLinks.values {
            if !link.id.isEmpty { wanted[link.service, default: []].insert(link.id) }
            if let sensor = link.sensor { wanted[sensor.service, default: []].insert(sensor.id) }
        }
        for sensor in tuyaSensors.values { wanted[sensor.service, default: []].insert(sensor.id) }
        var readings: [String: [String: DeviceReading]] = [:]
        var answered = false
        for (serviceId, ids) in wanted {
            guard let service = service(serviceId), service.isConnected, service.controlsDevices,
                  let result = try? await service.read(ids) else { continue }
            readings[serviceId] = result
            answered = true
        }
        guard answered else { return nil }
        var lights: [String: Any] = [:], acs: [String: Any] = [:], features: [String: Any] = [:]
        for (id, link) in serviceLinks {
            let reading = readings[link.service]?[link.id]
            if link.kind == .light, let light = reading?.light, reading?.online != false { lights[id] = light }
            if link.kind == .ac {
                var ac = reading?.online == false ? [:] : reading?.ac ?? [:]
                if let sensor = link.sensor, let t = readings[sensor.service]?[sensor.id]?.temperature { ac["roomTemp"] = t }
                if !ac.isEmpty { acs[id] = ac }
                if let known = reading?.features { features[id] = known }
            }
        }
        for (id, sensor) in tuyaSensors {
            if let t = readings[sensor.service]?[sensor.id]?.temperature { acs[id] = ["roomTemp": t] }
        }
        return ["lights": lights, "acs": acs, "features": features]
    }

    private func pollSmartLife() async -> [String: Any]? {
        let entries = links
        guard let cloud, !entries.isEmpty else { return nil }
        // Devices plus the temperature sensors that stand in for an AC's room reading.
        let ids = entries.values.flatMap { [$0.link["deviceId"] as? String, $0.link["sensorId"] as? String].compactMap { $0 } }
        guard let status = try? await cloud.status(of: Array(Set(ids)).filter { !$0.isEmpty }) else { return nil }
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
        return ["lights": lights, "acs": acs, "features": features]
    }

    public func listDevices() async throws -> [[String: Any]] {
        guard let cloud else { throw SmartLifeService.Failure(message: "Connect Smart Life first") }
        return try await cloud.listDevices()
    }

    /// Every device of every connected platform, in the editor's terms, plus what went
    /// wrong with the platforms that could not be asked.
    public func allDevices() async -> (devices: [[String: Any]], errors: [String: String]) {
        var devices: [[String: Any]] = []
        var errors: [String: String] = [:]
        if cloud != nil {
            do {
                devices += try await listDevices().map(Self.smartLifeDevice)
            } catch {
                errors["smartlife"] = error.localizedDescription
            }
        }
        for service in services where service.isConnected {
            do {
                devices += try await service.devices().map { $0.dictionary(service: service.id) }
            } catch {
                errors[service.id] = error.localizedDescription
            }
        }
        return (devices, errors)
    }

    /// A Smart Life device in the same shape as the other platforms' (plus its Tuya codes).
    static func smartLifeDevice(_ d: [String: Any]) -> [String: Any] {
        let codes = Set(d["codes"] as? [String] ?? [])
        let category = d["category"] as? String ?? ""
        let kind: DeviceKind
        if ["kt", "ktkzq", "infrared_ac"].contains(category) || TuyaMapper.isInfraredAC(codes) || codes.contains("temp_set") {
            kind = .ac
        } else if ["wsdcg", "wk", "wnykq"].contains(category) || (codes.contains("temp_current") && !codes.contains("switch_led")) {
            kind = .sensor
        } else {
            kind = .light
        }
        var caps: [String] = []
        if codes.contains("bright_value") || codes.contains("bright_value_v2") { caps.append("brightness") }
        if codes.contains("temp_value") || codes.contains("temp_value_v2") { caps.append("temp") }
        if codes.contains("colour_data") || codes.contains("colour_data_v2") { caps.append("color") }
        var out = d
        out["service"] = "smartlife"
        out["kind"] = kind.rawValue
        out["capabilities"] = caps
        out["room"] = nil
        out["detail"] = [d["product"] as? String, category].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return out
    }

    /// What the editor and the settings show for each platform.
    public var servicesInfo: [String: Any] {
        var out: [String: Any] = ["smartlife": smartLifeInfo.merging(["connected": isSmartLifeConnected || tuya.isConfigured]) { $1 }]
        for service in services { out[service.id] = service.info }
        return out
    }

    // MARK: - Connections shared between the Mac and its iPhones

    /// The platforms whose connection travels between paired devices. (Apple Home is the
    /// phone's own; a Smart Life session cannot be shared, Tuya rotates its tokens.)
    public static let shareablePlatforms = ["homeassistant", "hue"]

    /// When each shareable platform was last connected or disconnected on this device, or
    /// adopted from another one: the newer side wins when two devices disagree.
    private var stamps: [String: Double] {
        get {
            guard let data = try? Data(contentsOf: stampsURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
            return json
        }
        set { try? JSONSerialization.data(withJSONObject: newValue).write(to: stampsURL, options: .atomic) }
    }
    private let stampsURL: URL

    private func shareable(_ id: String) -> [String: Any]? {
        id == "homeassistant" ? homeAssistant.shareable : id == "hue" ? hue.shareable : nil
    }

    /// Connects Home Assistant (checking the address and token first) and remembers when.
    public func connectHomeAssistant(url: String, token: String) async throws {
        try await homeAssistant.connect(url: url, token: token)
        stamp("homeassistant")
    }

    /// Pairs with a Hue Bridge; throws `HueService.ButtonNotPressed` until its button is pressed.
    public func pairHue(host: String, bridgeId: String?, name: String?) async throws {
        try await hue.pair(host: host, bridgeId: bridgeId, name: name)
        stamp("hue")
    }

    /// Disconnects a platform; for Home Assistant and Hue the paired devices follow.
    public func disconnect(service id: String) {
        services.first { $0.id == id }?.disconnect()
        if Self.shareablePlatforms.contains(id) { stamp(id) }
    }

    private func stamp(_ id: String) {
        var all = stamps
        all[id] = max(Date().timeIntervalSince1970, (all[id] ?? 0) + 0.001)
        stamps = all
    }

    /// This device's Home Assistant and Hue connections for its paired devices: the address
    /// and token / bridge key plus when they were set, or `removed` after a disconnect.
    public var shareableConnections: [String: Any] {
        let known = stamps
        var out: [String: Any] = [:]
        for id in Self.shareablePlatforms {
            let updated = known[id] ?? 0
            if var config = shareable(id) {
                config["updated"] = updated
                out[id] = config
            } else if updated > 0 {
                out[id] = ["removed": true, "updated": updated]
            }
        }
        return out
    }

    /// Takes what another device shared, platform by platform, where it is newer than what
    /// this device has. A platform missing from `shared` is left alone. Returns true when a
    /// connection changed here.
    @discardableResult
    public func adoptConnections(_ shared: [String: Any]) -> Bool {
        var known = stamps
        var changed = false
        for id in Self.shareablePlatforms {
            guard let incoming = shared[id] as? [String: Any] else { continue }
            let theirs = (incoming["updated"] as? NSNumber)?.doubleValue ?? 0
            let ours = known[id]
            // A peer without stamps (an older version) only fills in what was never set here.
            let newer = theirs > 0 ? theirs > (ours ?? 0) : (ours ?? 0) == 0
            guard newer else { continue }
            let before = shareable(id).map { NSDictionary(dictionary: $0) }
            if incoming["removed"] as? Bool == true {
                services.first { $0.id == id }?.disconnect()
            } else if id == "homeassistant" {
                homeAssistant.adopt(incoming)
            } else {
                hue.adopt(incoming)
            }
            known[id] = theirs
            if shareable(id).map({ NSDictionary(dictionary: $0) }) != before { changed = true }
        }
        stamps = known
        return changed
    }

    /// Read-only snapshot of what Smart Life reports for the given devices.
    public func diagnostics(for ids: [String]) async -> [String: Any] {
        await smartLife.diagnostics(for: ids)
    }

    // MARK: - Smart Life account

    /// What the UI may know about the session: never the tokens.
    public var smartLifeInfo: [String: Any] { smartLife.publicInfo }
    public var isSmartLifeConnected: Bool { smartLife.isConfigured }
    public var smartLifeUserCode: String { smartLife.session?.userCode ?? "" }
    public var smartLifeAccount: String { smartLife.session?.username ?? "" }

    /// Asks Tuya for a login ticket; `qrContent` is what the QR code must contain.
    public func beginLogin(userCode: String) async throws -> (token: String, qrContent: String) {
        try await smartLife.beginLogin(userCode: userCode)
    }

    /// True once the user has confirmed the login in the Smart Life app.
    public func finishLogin(token: String, userCode: String) async -> Bool {
        (try? await smartLife.finishLogin(token: token, userCode: userCode)) ?? false
    }

    public func signOut() { smartLife.signOut() }

    // MARK: - Tuya Cloud project ("Advanced")

    public var tuyaInfo: [String: Any] { tuya.publicInfo }

    /// Stores the project credentials. An empty secret keeps the one already stored;
    /// an empty access id removes them.
    public func saveTuya(accessId: String, accessSecret: String, region: String) throws {
        let id = accessId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = accessSecret.isEmpty ? (tuya.credentials?.accessSecret ?? "")
            : accessSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        try tuya.save(id.isEmpty ? nil : TuyaService.Credentials(accessId: id, accessSecret: secret, region: region))
    }
}
