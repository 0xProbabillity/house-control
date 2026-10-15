import Foundation
import HouseCore

/// Smart Life for the device hub: the QR-linked account when there is one, otherwise a
/// Tuya Cloud project ("Advanced"). Builds that include this module pass
/// `SmartLifePlatform.init` to `DeviceHub(cloud:)`; the App Store build of the iPhone app
/// leaves it out.
@MainActor
public final class SmartLifePlatform: LinkedCloud {
    private let tuya: TuyaService
    private let smartLife: SmartLifeService
    private let infrared = InfraredRemote()

    /// `secret("smartlife")` keeps the session; the Tuya Cloud project lives in `directory`.
    public init(directory: URL, secret: (String) -> SecretStore) {
        tuya = TuyaService(directory: directory)
        smartLife = SmartLifeService(vault: secret("smartlife"))
    }

    /// The backend real devices are reached through: the QR-linked Smart Life account
    /// when there is one, otherwise a Tuya Cloud project, otherwise nothing (simulation).
    private var active: DeviceCloud? {
        smartLife.isConfigured ? smartLife : (tuya.isConfigured ? tuya : nil)
    }

    public var isConnected: Bool { active != nil }

    public var info: [String: Any] {
        smartLife.publicInfo.merging(["connected": isConnected]) { $1 }
    }

    // MARK: - LinkedCloud

    public func command(appId id: String, kind: String, link: [String: Any], patch: [String: Any],
                        state: [String: Any], log: EventLog) async throws {
        guard let cloud = active, let deviceId = link["deviceId"] as? String else { return }
        // The first command to a device may arrive before anything is known about it.
        await cloud.prepare(deviceId)
        let codes = cloud.knownCodes[deviceId] ?? []
        let send: ([[String: Any]]) async throws -> Void = { commands in
            guard !commands.isEmpty else { return }
            do {
                try await cloud.send(commands, to: deviceId)
                log.write("\(id) \(EventLog.describe(commands)) → ok")
            } catch {
                log.write("\(id) \(EventLog.describe(commands)) → \(error.localizedDescription)")
                throw error
            }
        }
        if kind == "light" {
            try await send(TuyaMapper.lightCommands(patch: patch, state: state, link: link, codes: codes,
                                                    ranges: cloud.knownRanges[deviceId] ?? [:]))
        } else if TuyaMapper.isInfraredAC(codes) {
            do {
                try await infrared.apply(patch: patch, state: state, to: deviceId,
                                         send: { try await send([$0]) }, note: { log.write("\(id) \($0)") })
            } catch let rejected as InfraredRemote.Rejection {
                throw CommandRejection(message: rejected.message, fields: rejected.fields)
            }
        } else {
            try await send(TuyaMapper.acCommands(patch: patch, link: link, codes: codes))
        }
    }

    public func poll(_ entries: [String: (kind: String, link: [String: Any])]) async -> [String: Any]? {
        guard let cloud = active, !entries.isEmpty else { return nil }
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

    public func devices() async throws -> [[String: Any]] {
        try await listDevices().map(Self.device)
    }

    /// The account's devices as Tuya reports them (with their data point codes).
    public func listDevices() async throws -> [[String: Any]] {
        guard let cloud = active else { throw SmartLifeService.Failure(message: "Connect Smart Life first") }
        return try await cloud.listDevices()
    }

    /// A Smart Life device in the same shape as the other platforms' (plus its Tuya codes).
    static func device(_ d: [String: Any]) -> [String: Any] {
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

    /// Read-only snapshot of what Smart Life reports for the given devices.
    public func diagnostics(for ids: [String]) async -> [String: Any] {
        await smartLife.diagnostics(for: ids)
    }

    // MARK: - Smart Life account

    /// What the UI may know about the session: never the tokens.
    public var smartLifeInfo: [String: Any] { smartLife.publicInfo }
    public var isSmartLifeConnected: Bool { smartLife.isConfigured }
    public var userCode: String { smartLife.session?.userCode ?? "" }
    public var account: String { smartLife.session?.username ?? "" }

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

public extension DeviceHub {
    /// The Smart Life side of this hub, when it was made with one.
    var smartLife: SmartLifePlatform? { cloud as? SmartLifePlatform }
}
