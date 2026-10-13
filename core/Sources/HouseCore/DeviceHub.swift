import Foundation

/// Everything between the UI and the real devices, shared by the Mac and the iPhone app:
/// which backend is connected, which device of the plan is linked to which Smart Life
/// device, sending the changes made in the panel and reading the devices' state back.
@MainActor
public final class DeviceHub {
    public let log: EventLog
    private let tuya: TuyaService
    private let smartLife: SmartLifeService
    /// The backend real devices are reached through: the QR-linked Smart Life account
    /// when there is one, otherwise a Tuya Cloud project, otherwise nothing (simulation).
    private var cloud: DeviceCloud? {
        smartLife.isConfigured ? smartLife : (tuya.isConfigured ? tuya : nil)
    }
    /// App device id -> its Smart Life link, for the devices of the active plan.
    private var links: [String: (kind: String, link: [String: Any])] = [:]
    /// The command in flight for each real device; the next one waits for it.
    private var commandTails: [String: Task<Void, Never>] = [:]
    private let infrared = InfraredRemote()

    /// Called after a command failed in a way that leaves the panel out of step with the
    /// devices, so the owner can read their state again.
    public var onStale: (() -> Void)?

    /// `session` is where the Smart Life session is kept; by default `smartlife.json` in `directory`.
    public init(directory: URL, session: SecretStore? = nil) {
        log = EventLog(directory: directory)
        tuya = TuyaService(directory: directory)
        smartLife = session.map { SmartLifeService(vault: $0) } ?? SmartLifeService(directory: directory)
    }

    // MARK: - Links

    public var isConnected: Bool { cloud != nil }
    public var hasLinks: Bool { !links.isEmpty }
    /// True when there is something to read from the cloud at all.
    public var canPoll: Bool { cloud != nil && !links.isEmpty }
    public var linkedDeviceCount: Int { links.count }

    /// Takes the device links from `plan`; nil (a bundled demo) means everything is simulated.
    public func setLinks(from plan: [String: Any]?) {
        links = [:]
        guard let plan else { return }
        for (kind, key) in [("light", "lights"), ("ac", "acs")] {
            for device in plan[key] as? [[String: Any]] ?? [] {
                guard let id = device["id"] as? String, let link = device["tuya"] as? [String: Any],
                      let deviceId = link["deviceId"] as? String, !deviceId.isEmpty else { continue }
                links[id] = (kind, link)
            }
        }
    }

    // MARK: - Commands

    /// Sends a change made in the panel to the real device and tells the panel how it went,
    /// so a rejected change can be rolled back there. Commands to one device run strictly
    /// one after another, in the order this is called.
    public func command(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
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
