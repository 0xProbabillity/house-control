import Foundation
import HouseCore
import CryptoKit

/// Minimal client for the Tuya Cloud OpenAPI ("Smart Home" project with the Smart Life
/// app account linked to it). Covers exactly what the app needs: list devices, read
/// their status, send commands.
@MainActor
final class TuyaService {
    struct Credentials: Codable {
        var accessId: String
        var accessSecret: String
        var region: String
    }

    struct Failure: LocalizedError {
        let message: String
        var code = ""
        var errorDescription: String? { message }
    }

    static let hosts: [String: String] = [
        "eu": "openapi.tuyaeu.com",        // Central Europe
        "eu-w": "openapi-weaz.tuyaeu.com", // Western Europe
        "us": "openapi.tuyaus.com",        // Western America
        "us-e": "openapi-ueaz.tuyaus.com", // Eastern America
        "cn": "openapi.tuyacn.com",
        "in": "openapi.tuyain.com",
        "sg": "openapi-sg.iotbing.com",
    ]

    private let fileURL: URL
    private(set) var credentials: Credentials?
    private var token: String?
    private var tokenExpiry = Date.distantPast
    /// Data-point codes each device reported, used to pick the right command dialect.
    private(set) var knownCodes: [String: Set<String>] = [:]
    private(set) var knownRanges: [String: TuyaMapper.Ranges] = [:]

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("tuya.json")
        if let data = try? Data(contentsOf: fileURL) {
            credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        }
    }

    var isConfigured: Bool {
        guard let c = credentials else { return false }
        return !c.accessId.isEmpty && !c.accessSecret.isEmpty && Self.hosts[c.region] != nil
    }

    /// What the UI may know: never the secret itself.
    var publicInfo: [String: Any] {
        ["configured": isConfigured, "accessId": credentials?.accessId ?? "", "region": credentials?.region ?? "eu",
         "hasSecret": !(credentials?.accessSecret.isEmpty ?? true)]
    }

    func save(_ new: Credentials?) throws {
        credentials = new
        token = nil
        tokenExpiry = .distantPast
        guard let new else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try JSONEncoder().encode(new).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - API

    /// Every device of the linked Smart Life account, with the DP codes it supports.
    func listDevices() async throws -> [[String: Any]] {
        var devices: [[String: Any]] = []
        var lastKey: String?
        repeat {
            var query = ["size": "50"]
            if let lastKey { query["last_row_key"] = lastKey }
            let result = try await request("GET", "/v1.0/iot-01/associated-users/devices", query: query)
            guard let page = result as? [String: Any] else { break }
            for d in page["devices"] as? [[String: Any]] ?? [] {
                guard let id = d["id"] as? String else { continue }
                let status = d["status"] as? [[String: Any]] ?? []
                let codes = status.compactMap { $0["code"] as? String }
                knownCodes[id] = Set(codes)
                devices.append([
                    "id": id,
                    "name": d["name"] as? String ?? id,
                    "category": d["category"] as? String ?? "",
                    "product": d["product_name"] as? String ?? "",
                    "online": d["online"] as? Bool ?? false,
                    "codes": codes,
                ])
            }
            lastKey = (page["has_more"] as? Bool ?? false) ? page["last_row_key"] as? String : nil
        } while lastKey != nil
        return devices
    }

    /// Current data points for the given devices, keyed by device id.
    func status(of ids: [String]) async throws -> [String: [[String: Any]]] {
        var out: [String: [[String: Any]]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 20).map({ Array(ids[$0..<min($0 + 20, ids.count)]) }) {
            let result = try await request("GET", "/v1.0/iot-03/devices/status", query: ["device_ids": chunk.joined(separator: ",")])
            for entry in result as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String, let status = entry["status"] as? [[String: Any]] else { continue }
                out[id] = status
                knownCodes[id] = Set(status.compactMap { $0["code"] as? String })
            }
        }
        return out
    }

    func send(_ commands: [[String: Any]], to deviceId: String) async throws {
        guard !commands.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: ["commands": commands])
        _ = try await request("POST", "/v1.0/iot-03/devices/\(deviceId)/commands", body: body)
    }

    // MARK: - Signing

    private func accessToken() async throws -> String {
        if let token, tokenExpiry > Date().addingTimeInterval(60) { return token }
        let result = try await request("GET", "/v1.0/token", query: ["grant_type": "1"], authorized: false)
        guard let dict = result as? [String: Any], let value = dict["access_token"] as? String else {
            throw Failure(message: "Tuya did not return an access token")
        }
        token = value
        tokenExpiry = Date().addingTimeInterval(TimeInterval(dict["expire_time"] as? Int ?? 3600))
        return value
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:],
                         body: Data? = nil, authorized: Bool = true, retry: Bool = true) async throws -> Any {
        guard let c = credentials, isConfigured, let host = Self.hosts[c.region] else {
            throw Failure(message: "Tuya credentials are not set")
        }
        let sorted = query.sorted { $0.key < $1.key }
        let queryString = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let signedURL = queryString.isEmpty ? path : "\(path)?\(queryString)"
        guard let url = URL(string: "https://\(host)\(signedURL)") else { throw Failure(message: "Bad request URL") }

        let bodyHash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
        let t = String(Int(Date().timeIntervalSince1970 * 1000))
        let token = authorized ? try await accessToken() : ""
        let payload = c.accessId + token + t + "\(method)\n\(bodyHash)\n\n\(signedURL)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: Data(c.accessSecret.utf8)))
        let sign = mac.map { String(format: "%02X", $0) }.joined()

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(c.accessId, forHTTPHeaderField: "client_id")
        req.setValue(sign, forHTTPHeaderField: "sign")
        req.setValue(t, forHTTPHeaderField: "t")
        req.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        if authorized { req.setValue(token, forHTTPHeaderField: "access_token") }
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Unexpected response from Tuya")
        }
        if json["success"] as? Bool == true { return json["result"] ?? NSNull() }
        let code = json["code"] as? Int ?? 0
        // 1010 / 1011: token expired or invalid. Fetch a fresh one once.
        if authorized, retry, code == 1010 || code == 1011 {
            self.token = nil
            return try await request(method, path, query: query, body: body, authorized: true, retry: false)
        }
        throw Failure(message: "\(json["msg"] as? String ?? "Tuya request failed") (code \(code))", code: String(code))
    }
}

/// Translates between the app's device state and Tuya's "standard instruction set".
/// Devices differ in which data points they expose and in their value ranges, so every
/// mapping checks the codes the device actually reported and silently skips what it cannot do.
enum TuyaMapper {
    /// (min, max) of a numeric data point, from the device specification when known.
    typealias Ranges = [String: (Double, Double)]

    private static let acModes = ["cool": "cold", "heat": "hot", "dry": "wet", "fan": "wind", "auto": "auto"]
    private static let acFans = ["auto": "auto", "low": "low", "medium": "mid", "high": "high", "turbo": "strong"]
    // Infrared ACs (a remote learned by an IR blaster) number their modes and fan speeds.
    private static let irModes = ["cool": 0, "heat": 1, "auto": 2, "fan": 3, "dry": 4]
    private static let irFans = ["auto": 0, "low": 1, "medium": 2, "high": 3, "turbo": 3]

    private static func pick(_ candidates: [String], in codes: Set<String>, override: Any?) -> String? {
        if let o = override as? String, !o.isEmpty { return o }
        return candidates.first { codes.contains($0) }
    }

    /// Range of a brightness / temperature point: the specification wins; otherwise the
    /// `_v2` points are 0…1000 and the legacy ones 0…255.
    private static func range(_ code: String, _ ranges: Ranges, floor: Double = 0) -> (Double, Double) {
        if let r = ranges[code], r.1 > r.0 { return r }
        return code.hasSuffix("_v2") ? (floor > 0 ? 10 : 0, 1000) : (floor, 255)
    }

    static func lightCommands(patch: [String: Any], state: [String: Any], link: [String: Any],
                              codes: Set<String>, ranges: Ranges = [:]) -> [[String: Any]] {
        let custom = link["codes"] as? [String: Any] ?? [:]
        var out: [[String: Any]] = []
        if let on = patch["on"] as? Bool {
            // A plain plug only has a switch; assume switch_1 when the device has not reported yet.
            let code = pick(["switch_led", "switch_1", "switch"], in: codes, override: custom["switch"]) ?? "switch_1"
            out.append(["code": code, "value": on])
        }
        if let b = patch["brightness"] as? Double, let code = pick(["bright_value_v2", "bright_value"], in: codes, override: nil) {
            let (lo, hi) = range(code, ranges, floor: 25)
            out.append(["code": code, "value": Int((lo + b * (hi - lo)).rounded())])
        }
        if let k = patch["temp"] as? Double, let code = pick(["temp_value_v2", "temp_value"], in: codes, override: nil) {
            let t = max(0, min(1, (k - 2200) / (6500 - 2200)))
            let (lo, hi) = range(code, ranges)
            if codes.contains("work_mode") { out.append(["code": "work_mode", "value": "white"]) }
            out.append(["code": code, "value": Int((lo + t * (hi - lo)).rounded())])
        }
        if let hex = patch["color"] as? String, let (h, s, _) = hsv(hex),
           let code = pick(["colour_data_v2", "colour_data"], in: codes, override: nil) {
            // Saturation and value share the brightness scale of the same generation.
            let scale = range(code == "colour_data_v2" ? "bright_value_v2" : "bright_value", ranges).1 > 255 ? 1000.0 : 255.0
            let v = max(0.01, state["brightness"] as? Double ?? 1)
            if codes.contains("work_mode") { out.append(["code": "work_mode", "value": "colour"]) }
            // Sent as a JSON string, which is also how the device reports it.
            out.append(["code": code, "value": "{\"h\":\(Int(h)),\"s\":\(Int(s * scale)),\"v\":\(Int(v * scale))}"])
        }
        return out
    }

    static func lightState(from status: [[String: Any]], ranges: Ranges = [:]) -> [String: Any] {
        var out: [String: Any] = [:]
        for dp in status {
            guard let code = dp["code"] as? String, let value = dp["value"] else { continue }
            switch code {
            case "switch_led", "switch_1", "switch":
                if out["on"] == nil, let v = value as? Bool { out["on"] = v }
            case "bright_value_v2", "bright_value":
                if let v = value as? Double {
                    let (lo, hi) = range(code, ranges, floor: 25)
                    out["brightness"] = max(0.05, min(1, (v - lo) / (hi - lo)))
                }
            case "temp_value_v2", "temp_value":
                if let v = value as? Double {
                    let (lo, hi) = range(code, ranges)
                    out["temp"] = 2200 + max(0, min(1, (v - lo) / (hi - lo))) * 4300
                }
            default: break
            }
        }
        return out
    }

    /// True for an AC that is a remote learned by an infrared blaster. Those take the
    /// "PowerOn / PowerOff / T / M / F" key set and never report their state back.
    static func isInfraredAC(_ codes: Set<String>) -> Bool {
        codes.contains("PowerOn") || codes.contains("PowerOff")
    }

    /// One key press of an infrared remote, and the piece of app state it carries.
    struct InfraredKey {
        let field: String
        let command: [String: Any]
    }

    /// The key presses that bring an infrared AC to `patch`. Order matters for a remote:
    /// power first, then mode, then the set-point and fan.
    static func infraredKeys(patch: [String: Any]) -> [InfraredKey] {
        var out: [InfraredKey] = []
        if let on = patch["on"] as? Bool {
            let key = on ? "PowerOn" : "PowerOff"
            out.append(InfraredKey(field: "on", command: ["code": key, "value": key]))
        }
        if let m = patch["mode"] as? String, let v = irModes[m] {
            out.append(InfraredKey(field: "mode", command: ["code": "M", "value": v]))
        }
        if let t = patch["target"] as? Double {
            out.append(InfraredKey(field: "target", command: ["code": "T", "value": Int(t)]))
        }
        if let f = patch["fan"] as? String, let v = irFans[f] {
            out.append(InfraredKey(field: "fan", command: ["code": "F", "value": v]))
        }
        return out
    }

    /// What the panel may offer for a linked AC. Controls the device has no function for
    /// are hidden instead of pretending to work. Nil until the functions are known.
    static func acFeatures(codes: Set<String>, ranges: Ranges) -> [String: Any]? {
        guard !codes.isEmpty else { return nil }
        let allModes = ["cool", "heat", "dry", "fan", "auto"]
        if isInfraredAC(codes) {
            let m = ranges["M"] ?? (0, 4), f = ranges["F"] ?? (0, 3)
            return [
                "infrared": true,
                "modes": allModes.filter { Double(irModes[$0] ?? 99) >= m.0 && Double(irModes[$0] ?? 99) <= m.1 },
                // Turbo shares the top speed with High on a remote, so it is not offered twice.
                "fans": ["auto", "low", "medium", "high"].filter { Double(irFans[$0] ?? 99) >= f.0 && Double(irFans[$0] ?? 99) <= f.1 },
                "sleep": false, "eco": false, "swing": false,
            ]
        }
        return [
            "infrared": false,
            "modes": codes.contains("mode") ? allModes : [],
            "fans": codes.contains("fan_speed_enum") || codes.contains("windspeed") ? ["auto", "low", "medium", "high", "turbo"] : [],
            "sleep": codes.contains("sleep"), "eco": codes.contains("eco"), "swing": false,
        ]
    }

    static func acCommands(patch: [String: Any], link: [String: Any], codes: Set<String>) -> [[String: Any]] {
        let custom = link["codes"] as? [String: Any] ?? [:]
        var out: [[String: Any]] = []

        if isInfraredAC(codes) { return infraredKeys(patch: patch).map(\.command) }

        if let on = patch["on"] as? Bool {
            out.append(["code": pick(["switch", "power", "switch_1"], in: codes, override: custom["switch"]) ?? "switch", "value": on])
        }
        if let t = patch["target"] as? Double {
            out.append(["code": pick(["temp_set"], in: codes, override: custom["target"]) ?? "temp_set", "value": Int(t)])
        }
        if let m = patch["mode"] as? String, let v = acModes[m] {
            out.append(["code": pick(["mode"], in: codes, override: custom["mode"]) ?? "mode", "value": v])
        }
        if let f = patch["fan"] as? String, let v = acFans[f],
           let code = pick(["fan_speed_enum", "windspeed"], in: codes, override: custom["fan"]) {
            out.append(["code": code, "value": v])
        }
        if let s = patch["sleep"] as? Bool, codes.contains("sleep") { out.append(["code": "sleep", "value": s]) }
        if let e = patch["eco"] as? Bool, codes.contains("eco") { out.append(["code": "eco", "value": e]) }
        return out
    }

    static func acState(from status: [[String: Any]]) -> [String: Any] {
        var out: [String: Any] = [:]
        for dp in status {
            guard let code = dp["code"] as? String, let value = dp["value"] else { continue }
            switch code {
            case "switch", "power": if let v = value as? Bool { out["on"] = v }
            case "temp_set": if let v = value as? Double { out["target"] = v }
            case "temp_current": if let v = value as? Double { out["roomTemp"] = v }
            case "mode": if let v = value as? String, let m = acModes.first(where: { $0.value == v })?.key { out["mode"] = m }
            case "fan_speed_enum", "windspeed": if let v = value as? String, let f = acFans.first(where: { $0.value == v })?.key { out["fan"] = f }
            default: break
            }
        }
        return out
    }

    /// Reading of a temperature sensor in °C (Tuya reports tenths of a degree).
    static func sensorTemperature(from status: [[String: Any]]) -> Double? {
        for dp in status {
            guard let code = dp["code"] as? String, ["temp_current", "va_temperature"].contains(code),
                  let v = dp["value"] as? Double else { continue }
            return abs(v) > 60 ? v / 10 : v
        }
        return nil
    }

    private static func hsv(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = Int(s, radix: 16) else { return nil }
        let r = Double((n >> 16) & 255) / 255, g = Double((n >> 8) & 255) / 255, b = Double(n & 255) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}
