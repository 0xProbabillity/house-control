import Foundation
import CryptoKit
import HouseCore

/// What the app needs from a device backend, whichever way the account is connected.
@MainActor
protocol DeviceCloud: AnyObject {
    var isConfigured: Bool { get }
    var knownCodes: [String: Set<String>] { get }
    /// Numeric ranges of each device's data points (brightness scales differ per model).
    var knownRanges: [String: TuyaMapper.Ranges] { get }
    func listDevices() async throws -> [[String: Any]]
    func status(of ids: [String]) async throws -> [String: [[String: Any]]]
    func send(_ commands: [[String: Any]], to deviceId: String) async throws
    /// Makes sure the device's functions are known before the first command is built.
    func prepare(_ deviceId: String) async
}

extension TuyaService: DeviceCloud {
    func prepare(_ deviceId: String) async {}
}

/// Tuya's error code behind a failed request, whichever backend raised it.
func tuyaCode(of error: Error) -> String {
    (error as? SmartLifeService.Failure)?.code ?? (error as? TuyaService.Failure)?.code ?? ""
}

/// Smart Life account access without a Tuya developer project: the user approves a QR
/// login in the Smart Life app and the app talks to Tuya's "device sharing" gateway.
/// This is a Swift port of the open-source `tuya-device-sharing-sdk` that the Home
/// Assistant Tuya integration is built on, and it identifies itself the same way.
@MainActor
final class SmartLifeService: DeviceCloud {
    private static let clientId = "HA_3y9q4ak7g4ephrvke"
    private static let schema = "haauthorize"
    private static let loginHost = "https://apigw.iotbing.com"

    struct Session: Codable {
        var userCode: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double   // ms since 1970
        var uid: String
        var endpoint: String
        var username: String
    }

    struct Failure: LocalizedError {
        let message: String
        /// Tuya's error code when the cloud answered with one ("2008", "1109", …).
        var code = ""
        var errorDescription: String? { message }
    }

    private let vault: SecretStore
    private(set) var session: Session?
    private var sessionStamp: Date?
    private var loaded = false
    private(set) var knownCodes: [String: Set<String>] = [:]
    private(set) var knownRanges: [String: TuyaMapper.Ranges] = [:]
    private var refreshing = false

    /// The session lives in `smartlife.json` inside `directory`.
    convenience init(directory: URL) {
        self.init(vault: FileSecretStore(url: directory.appendingPathComponent("smartlife.json")))
    }

    init(vault: SecretStore) {
        self.vault = vault
        reloadSession()
    }

    /// Refreshing rotates the refresh token, so a second process (`--diagnose` next to the
    /// running app) must pick up what the other one stored instead of carrying on with a
    /// token that no longer works.
    private func reloadSession() {
        let stamp = vault.stamp
        guard !loaded || stamp != sessionStamp else { return }
        loaded = true
        sessionStamp = stamp
        session = vault.read().flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }

    var isConfigured: Bool { session != nil }

    var publicInfo: [String: Any] {
        ["connected": isConfigured, "userCode": session?.userCode ?? "", "account": session?.username ?? ""]
    }

    private func store(_ new: Session?) {
        session = new
        vault.write(new.flatMap { try? JSONEncoder().encode($0) })
        sessionStamp = vault.stamp
    }

    func signOut() {
        store(nil)
        knownCodes = [:]
        knownRanges = [:]
    }

    // MARK: - QR login

    /// Asks Tuya for a login ticket; the returned string is what the QR code must contain.
    func beginLogin(userCode: String) async throws -> (token: String, qrContent: String) {
        let code = userCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let encoded = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw Failure(message: "Enter the User Code from the Smart Life app first.")
        }
        let url = URL(string: "\(Self.loginHost)/v1.0/m/life/home-assistant/qrcode/tokens?clientid=\(Self.clientId)&usercode=\(encoded)&schema=\(Self.schema)")!
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        let json = try await Self.json(for: request)
        guard json["success"] as? Bool == true, let result = json["result"] as? [String: Any],
              let token = result["qrcode"] as? String else {
            throw Failure(message: Self.explain(json, fallback: "Tuya did not accept this User Code."))
        }
        return (token, "tuyaSmart--qrLogin?token=\(token)")
    }

    /// True once the user has confirmed the login in the Smart Life app.
    func finishLogin(token: String, userCode: String) async throws -> Bool {
        let code = userCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? code
        let url = URL(string: "\(Self.loginHost)/v1.0/m/life/home-assistant/qrcode/tokens/\(token)?clientid=\(Self.clientId)&usercode=\(encoded)")!
        let json = try await Self.json(for: URLRequest(url: url, timeoutInterval: 12))
        guard json["success"] as? Bool == true, let r = json["result"] as? [String: Any],
              let access = r["access_token"] as? String, let refresh = r["refresh_token"] as? String,
              let endpoint = r["endpoint"] as? String else { return false }
        let now = (json["t"] as? Double) ?? Date().timeIntervalSince1970 * 1000
        store(Session(userCode: code, accessToken: access, refreshToken: refresh,
                      expiresAt: now + ((r["expire_time"] as? Double) ?? 7200) * 1000,
                      uid: r["uid"] as? String ?? "", endpoint: endpoint,
                      username: r["username"] as? String ?? ""))
        return true
    }

    static func qrImageDataURL(for text: String) -> String? {
        QRCode.png(for: text).map { "data:image/png;base64,\($0.base64EncodedString())" }
    }

    // MARK: - Devices

    func listDevices() async throws -> [[String: Any]] {
        var devices: [[String: Any]] = []
        let homes = try await request("GET", "/v1.0/m/life/users/homes") as? [[String: Any]] ?? []
        for home in homes {
            // ownerId arrives as a number or a string depending on the account.
            guard let homeId = (home["ownerId"] as? String) ?? (home["ownerId"] as? NSNumber)?.stringValue else { continue }
            let list = try await request("GET", "/v1.0/m/life/ha/home/devices", query: ["homeId": homeId]) as? [[String: Any]] ?? []
            for d in list {
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
                    "home": home["name"] as? String ?? "",
                ])
            }
        }
        return devices
    }

    func status(of ids: [String]) async throws -> [String: [[String: Any]]] {
        var out: [String: [[String: Any]]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 20).map({ Array(ids[$0..<min($0 + 20, ids.count)]) }) {
            let list = try await request("GET", "/v1.0/m/life/ha/devices/detail", query: ["devIds": chunk.joined(separator: ",")]) as? [[String: Any]] ?? []
            for d in list {
                guard let id = d["id"] as? String, let status = d["status"] as? [[String: Any]] else { continue }
                out[id] = status
                knownCodes[id, default: []].formUnion(status.compactMap { $0["code"] as? String })
            }
        }
        for id in ids where knownRanges[id] == nil { await loadSpecification(of: id) }
        return out
    }

    func send(_ commands: [[String: Any]], to deviceId: String) async throws {
        guard !commands.isEmpty else { return }
        _ = try await request("POST", "/v1.1/m/thing/\(deviceId)/commands", body: ["commands": commands])
    }

    /// Read-only snapshot for diagnostics: raw status and specification of the given devices.
    func diagnostics(for ids: [String]) async -> [String: Any] {
        var out: [String: Any] = [:]
        let details = (try? await request("GET", "/v1.0/m/life/ha/devices/detail", query: ["devIds": ids.joined(separator: ",")])) as? [[String: Any]] ?? []
        for d in details {
            guard let id = d["id"] as? String else { continue }
            var entry: [String: Any] = [:]
            for key in ["name", "category", "product_name", "online", "status", "sub"] { entry[key] = d[key] ?? NSNull() }
            do { entry["specification"] = try await request("GET", "/v1.1/m/life/\(id)/specifications") }
            catch { entry["specification_error"] = error.localizedDescription }
            // How the cloud maps raw data points to status codes; also shows what it last knew.
            do { entry["strategy"] = try await request("GET", "/v1.0/m/life/devices/\(id)/status") }
            catch { entry["strategy_error"] = error.localizedDescription }
            out[id] = entry
        }
        return out
    }

    func prepare(_ deviceId: String) async {
        if knownRanges[deviceId] == nil { await loadSpecification(of: deviceId) }
    }

    /// Functions and value ranges of a device; fetched once. Some devices (Zigbee bulbs,
    /// infrared remotes) report no status at all, so the specification is the only place
    /// that says which commands they understand.
    private func loadSpecification(of id: String) async {
        knownRanges[id] = [:] // remembered even on failure so it is not retried on every poll
        guard let spec = try? await request("GET", "/v1.1/m/life/\(id)/specifications") as? [String: Any] else { return }
        var ranges: TuyaMapper.Ranges = [:]
        var codes = knownCodes[id] ?? []
        for key in ["status", "functions"] {
            for item in spec[key] as? [[String: Any]] ?? [] {
                guard let code = item["code"] as? String else { continue }
                codes.insert(code)
                guard let raw = item["values"] as? String,
                      let values = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let lo = values["min"] as? Double, let hi = values["max"] as? Double else { continue }
                ranges[code] = (lo, hi)
            }
        }
        knownCodes[id] = codes
        knownRanges[id] = ranges
    }

    // MARK: - Encrypted, signed transport

    private func refreshIfNeeded() async {
        guard let s = session, !refreshing, s.expiresAt - 60_000 < Date().timeIntervalSince1970 * 1000 else { return }
        refreshing = true
        defer { refreshing = false }
        guard let result = try? await request("GET", "/v1.0/m/token/\(s.refreshToken)", refresh: false) as? [String: Any],
              let access = result["accessToken"] as? String, let refresh = result["refreshToken"] as? String else { return }
        var next = s
        next.accessToken = access
        next.refreshToken = refresh
        next.expiresAt = Date().timeIntervalSince1970 * 1000 + ((result["expireTime"] as? Double) ?? 7200) * 1000
        if let uid = result["uid"] as? String { next.uid = uid }
        store(next)
    }

    private func request(_ method: String, _ path: String, query: [String: Any] = [:],
                         body: [String: Any] = [:], refresh: Bool = true) async throws -> Any {
        reloadSession()
        if refresh { await refreshIfNeeded() }
        guard let s = session else { throw Failure(message: "Not signed in to Smart Life") }

        let rid = UUID().uuidString.lowercased()
        let hashKey = Transport.md5Hex(rid + s.refreshToken)
        let secret = Transport.secret(requestId: rid, hashKey: hashKey)

        var queryEnc = ""
        var urlString = s.endpoint + path
        if !query.isEmpty {
            queryEnc = try Transport.encrypt(Transport.compactJSON(query), secret: secret)
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            urlString += "?encdata=" + (queryEnc.addingPercentEncoding(withAllowedCharacters: allowed) ?? queryEnc)
        }
        var bodyEnc = ""
        if !body.isEmpty { bodyEnc = try Transport.encrypt(Transport.compactJSON(body), secret: secret) }
        guard let url = URL(string: urlString) else { throw Failure(message: "Bad request URL") }

        let t = String(Int(Date().timeIntervalSince1970 * 1000))
        let headers = [("X-appKey", Self.clientId), ("X-requestId", rid), ("X-sid", ""), ("X-time", t), ("X-token", s.accessToken)]

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = method
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        req.setValue(Transport.sign(hashKey: hashKey, headers: headers, query: queryEnc, body: bodyEnc), forHTTPHeaderField: "X-sign")
        if !bodyEnc.isEmpty {
            req.httpBody = try JSONSerialization.data(withJSONObject: ["encdata": bodyEnc])
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let json = try await Self.json(for: req)
        guard json["success"] as? Bool == true else {
            throw Failure(message: Self.explain(json, fallback: "Smart Life request failed"), code: Self.code(of: json))
        }
        guard let cipher = json["result"] as? String else { return json["result"] ?? NSNull() }
        let plain = try Transport.decrypt(cipher, secret: secret)
        return (try? JSONSerialization.jsonObject(with: Data(plain.utf8), options: [.fragmentsAllowed])) ?? plain
    }

    private static func json(for request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Unexpected response from Tuya")
        }
        return json
    }

    private static func code(of json: [String: Any]) -> String {
        (json["code"] as? String) ?? (json["code"] as? NSNumber)?.stringValue ?? ""
    }

    private static func explain(_ json: [String: Any], fallback: String) -> String {
        let code = code(of: json)
        // 2001: the cloud cannot reach the device (unplugged, or only paired over Bluetooth).
        if code == "2001" { return "device is offline — Smart Life cannot reach it over Wi-Fi (code 2001)" }
        let msg = json["msg"] as? String ?? fallback
        return code.isEmpty ? msg : "\(msg) (code \(code))"
    }

    /// The gateway's request envelope: per-request AES-GCM key derived from the request id
    /// and the refresh token, payloads sent as `encdata`, HMAC over headers + payloads.
    enum Transport {
        private static let alphabet = Array("ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678")

        static func md5Hex(_ text: String) -> String {
            Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        static func secret(requestId: String, hashKey: String) -> String {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(hashKey.utf8), using: SymmetricKey(data: Data(requestId.utf8)))
            return String(mac.map { String(format: "%02x", $0) }.joined().prefix(16))
        }

        static func sign(hashKey: String, headers: [(String, String)], query: String, body: String) -> String {
            let text = headers.filter { !$0.1.isEmpty }.map { "\($0.0)=\($0.1)" }.joined(separator: "||") + query + body
            let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(hashKey.utf8)))
            return mac.map { String(format: "%02x", $0) }.joined()
        }

        static func compactJSON(_ object: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        static func encrypt(_ plain: String, secret: String, nonce fixed: String? = nil) throws -> String {
            let nonceText = fixed ?? String((0..<12).map { _ in alphabet.randomElement()! })
            let nonce = try AES.GCM.Nonce(data: Data(nonceText.utf8))
            let box = try AES.GCM.seal(Data(plain.utf8), using: SymmetricKey(data: Data(secret.utf8)), nonce: nonce)
            return Data(nonceText.utf8).base64EncodedString() + (box.ciphertext + box.tag).base64EncodedString()
        }

        static func decrypt(_ cipher: String, secret: String) throws -> String {
            guard let data = Data(base64Encoded: cipher), data.count > 28 else {
                throw Failure(message: "Could not decode the response from Smart Life")
            }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: data.prefix(12)),
                                            ciphertext: data.dropFirst(12).dropLast(16), tag: data.suffix(16))
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: Data(secret.utf8)))
            return String(data: plain, encoding: .utf8) ?? ""
        }
    }
}
