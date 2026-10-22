import CryptoKit
import Foundation

/// A Philips Hue Bridge on the local network, through its own API (CLIP v2). No cloud and no
/// account: the bridge hands out a key when its round button is pressed. Hue lamps become the
/// plan's lamps; the temperature reported by Hue motion sensors can stand in for an AC's room
/// reading. The bridge's event stream tells the hub at once when a lamp changes elsewhere.
@MainActor
public final class HueService: DeviceService {
    public let id = "hue"
    public let title = "Philips Hue"
    public var onChange: (() -> Void)?

    struct Config: Codable {
        var host: String
        var key: String
        var bridgeId: String?
        var name: String?
        /// SHA-256 of the bridge's certificate, remembered when it was paired: the bridge's
        /// certificate is self-signed, so it is trusted on first use and checked ever after.
        var certificate: String?
    }

    private let vault: SecretStore
    private var config: Config?
    private let trust = BridgeTrust()
    private let session: URLSession
    /// The event stream stays open for hours: it gets a session without the short timeout.
    private let streamSession: URLSession
    private var stream: Task<Void, Never>?
    private var watched: Set<String> = []

    public init(vault: SecretStore) {
        self.vault = vault
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        let long = URLSessionConfiguration.ephemeral
        long.timeoutIntervalForRequest = 600 // the bridge sends a keep-alive well within this
        streamSession = URLSession(configuration: long, delegate: trust, delegateQueue: nil)
        var saved = vault.read().flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        if var previous = saved, previous.host.lowercased().hasPrefix("[fe80:"),
           !previous.host.contains("]:"),
           let hostname = Self.bonjourHostname(bridgeId: previous.bridgeId) {
            // Older builds saved the interface-scoped IPv6 selected during discovery. Keep
            // the paired key and certificate pin, but move requests to the bridge's stable mDNS name.
            previous.host = hostname
            saved = previous
            if let encoded = try? JSONEncoder().encode(previous) { vault.write(encoded) }
        }
        config = saved
        if let config { trust.pin(host: config.host, fingerprint: config.certificate); listen() }
    }

    static func bonjourHostname(bridgeId: String?) -> String? {
        guard let bridgeId, bridgeId.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "-" }) else { return nil }
        let id = Array(bridgeId.lowercased().filter(\.isHexDigit))
        // Hue's 16-digit EUI-64 bridge ID contains FFFE between the MAC address halves.
        guard id.count == 16, String(id[6..<10]) == "fffe" else { return nil }
        return String(id[0..<6]) + String(id[10..<16]) + ".local"
    }

    public var isConnected: Bool { config != nil }

    public var info: [String: Any] {
        guard let config else { return ["connected": false] }
        return ["connected": true, "host": config.host, "name": config.name ?? "Hue Bridge", "bridgeId": config.bridgeId ?? ""]
    }

    public var shareable: [String: Any]? {
        guard let config, let data = try? JSONEncoder().encode(config) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public func adopt(_ shared: [String: Any]?) {
        guard let shared, let data = try? JSONSerialization.data(withJSONObject: shared),
              let incoming = try? JSONDecoder().decode(Config.self, from: data) else {
            if config != nil { disconnect() }
            return
        }
        guard incoming.host != config?.host || incoming.key != config?.key else { return }
        config = incoming
        vault.write(data)
        trust.pin(host: incoming.host, fingerprint: incoming.certificate)
        listen()
    }

    public func disconnect() {
        config = nil
        vault.write(nil)
        stream?.cancel()
        stream = nil
    }

    public func watch(_ ids: Set<String>) { watched = ids }

    // MARK: - Pairing

    /// Asks the bridge at `host` for a key. Throws `ButtonNotPressed` until someone presses
    /// the round button on the bridge (it then accepts pairing for 30 seconds).
    public struct ButtonNotPressed: LocalizedError {
        public var errorDescription: String? { "Press the round button on the Hue Bridge." }
    }

    public func pair(host raw: String, bridgeId: String? = nil, name: String? = nil) async throws {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, let url = URL(string: "https://\(host)/api") else { throw ServiceFailure("Enter the bridge’s address") }
        trust.pin(host: host, fingerprint: nil) // trust on first use, remember below
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        #if os(iOS)
        let device = "iPhone"
        #else
        let device = "Mac"
        #endif
        request.httpBody = try JSONSerialization.data(withJSONObject: ["devicetype": "house_control#\(device)", "generateclientkey": true])
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw ServiceFailure("No Hue Bridge answered at \(host): \(error.localizedDescription)")
        }
        let answer = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first ?? [:]
        if let error = answer["error"] as? [String: Any] {
            if (error["type"] as? Int) == 101 { throw ButtonNotPressed() }
            throw ServiceFailure("The bridge said: \(error["description"] as? String ?? "error")")
        }
        guard let key = (answer["success"] as? [String: Any])?["username"] as? String else {
            throw ServiceFailure("The bridge at \(host) did not answer like a Hue Bridge")
        }
        var paired = Config(host: host, key: key, bridgeId: bridgeId, name: name, certificate: trust.fingerprint(for: host))
        config = paired
        // Fill in the bridge's own name for the editor.
        if let bridge = try? await get("/clip/v2/resource/bridge").first,
           let device = try? await get("/clip/v2/resource/device").first(where: {
               (($0["services"] as? [[String: Any]]) ?? []).contains { $0["rid"] as? String == bridge["id"] as? String }
           }) {
            paired.bridgeId = bridge["bridge_id"] as? String ?? bridgeId
            paired.name = (device["metadata"] as? [String: Any])?["name"] as? String ?? name
        }
        config = paired
        vault.write(try? JSONEncoder().encode(paired))
        listen()
    }

    // MARK: - Devices

    public func devices() async throws -> [ServiceDevice] {
        async let lights = get("/clip/v2/resource/light")
        async let rooms = get("/clip/v2/resource/room")
        async let sensors = get("/clip/v2/resource/temperature")
        async let hardware = get("/clip/v2/resource/device")
        async let links = get("/clip/v2/resource/zigbee_connectivity")
        let (lightList, roomList, sensorList, deviceList, linkList) = try await (lights, rooms, sensors, hardware, links)

        let roomOf = Self.roomIndex(roomList)
        let deviceName = Dictionary(deviceList.compactMap { d -> (String, String)? in
            guard let id = d["id"] as? String, let name = (d["metadata"] as? [String: Any])?["name"] as? String else { return nil }
            return (id, name)
        }, uniquingKeysWith: { a, _ in a })
        let offline = Set(linkList.compactMap { l -> String? in
            (l["status"] as? String) == "connected" ? nil : (l["owner"] as? [String: Any])?["rid"] as? String
        })

        var out: [ServiceDevice] = []
        for light in lightList {
            guard var device = Self.device(fromLight: light) else { continue }
            let owner = (light["owner"] as? [String: Any])?["rid"] as? String ?? ""
            device.room = roomOf[owner]
            device.online = !offline.contains(owner)
            out.append(device)
        }
        for sensor in sensorList {
            guard let id = sensor["id"] as? String else { continue }
            let owner = (sensor["owner"] as? [String: Any])?["rid"] as? String ?? ""
            var device = ServiceDevice(id: id, name: deviceName[owner] ?? "Hue sensor", kind: .sensor, room: roomOf[owner])
            device.detail = "temperature sensor"
            device.online = !offline.contains(owner)
            out.append(device)
        }
        return out.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    public func read(_ ids: Set<String>) async throws -> [String: DeviceReading] {
        guard !ids.isEmpty else { return [:] }
        async let lights = get("/clip/v2/resource/light")
        async let sensors = get("/clip/v2/resource/temperature")
        let (lightList, sensorList) = try await (lights, sensors)
        var out: [String: DeviceReading] = [:]
        for light in lightList {
            guard let id = light["id"] as? String, ids.contains(id) else { continue }
            out[id] = DeviceReading(light: Self.lightState(light))
        }
        for sensor in sensorList {
            guard let id = sensor["id"] as? String, ids.contains(id) else { continue }
            out[id] = DeviceReading(temperature: Self.temperature(sensor))
        }
        return out
    }

    public func send(kind: DeviceKind, id: String, patch: [String: Any], state: [String: Any]) async throws {
        guard kind == .light else { throw ServiceFailure("Hue has no air conditioners") }
        let body = Self.lightBody(patch: DeviceKind.withPower(patch, state: state))
        guard !body.isEmpty else { return }
        let answer = try await call("PUT", "/clip/v2/resource/light/\(id)", body: body)
        if let errors = answer["errors"] as? [[String: Any]], let first = errors.first {
            throw ServiceFailure("Hue: \(first["description"] as? String ?? "the bridge refused the change")")
        }
    }

    // MARK: - Mapping

    static func roomIndex(_ rooms: [[String: Any]]) -> [String: String] {
        var out: [String: String] = [:]
        for room in rooms {
            guard let name = (room["metadata"] as? [String: Any])?["name"] as? String else { continue }
            for child in room["children"] as? [[String: Any]] ?? [] {
                if let rid = child["rid"] as? String { out[rid] = name }
            }
        }
        return out
    }

    static func device(fromLight light: [String: Any]) -> ServiceDevice? {
        guard let id = light["id"] as? String else { return nil }
        let name = (light["metadata"] as? [String: Any])?["name"] as? String ?? "Hue light"
        var device = ServiceDevice(id: id, name: name, kind: .light)
        var caps: [String] = []
        if light["dimming"] != nil { caps.append("brightness") }
        if light["color_temperature"] != nil { caps.append("temp") }
        if light["color"] != nil { caps.append("color") }
        device.capabilities = caps
        let archetype = (light["metadata"] as? [String: Any])?["archetype"] as? String ?? "light"
        device.detail = "\(archetype.replacingOccurrences(of: "_", with: " ")) · " + (caps.isEmpty ? "on/off" : caps.joined(separator: ", "))
        return device
    }

    static func lightState(_ light: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let on = (light["on"] as? [String: Any])?["on"] as? Bool { out["on"] = on }
        if let b = (light["dimming"] as? [String: Any])?.double("brightness") { out["brightness"] = max(0.05, min(1, b / 100)) }
        let ct = light["color_temperature"] as? [String: Any]
        if ct?["mirek_valid"] as? Bool == true, let mirek = ct?.double("mirek") {
            out["temp"] = max(2200, min(6500, ColorMath.kelvin(mired: mirek)))
            out["color"] = NSNull()
        } else if let xy = (light["color"] as? [String: Any])?["xy"] as? [String: Any],
                  let x = xy.double("x"), let y = xy.double("y") {
            out["color"] = ColorMath.hex(x: x, y: y)
        }
        return out
    }

    static func temperature(_ sensor: [String: Any]) -> Double? {
        let t = sensor["temperature"] as? [String: Any]
        return (t?["temperature_report"] as? [String: Any])?.double("temperature") ?? t?.double("temperature")
    }

    static func lightBody(patch: [String: Any]) -> [String: Any] {
        var body: [String: Any] = [:]
        if let on = patch["on"] as? Bool { body["on"] = ["on": on] }
        if let b = patch["brightness"] as? Double { body["dimming"] = ["brightness": (b * 1000).rounded() / 10] }
        if let k = patch["temp"] as? Double { body["color_temperature"] = ["mirek": Int(ColorMath.mired(kelvin: k).rounded())] }
        if let hex = patch["color"] as? String, let (x, y) = ColorMath.xy(hex) { body["color"] = ["xy": ["x": x, "y": y]] }
        return body
    }

    // MARK: - HTTP

    private func get(_ path: String) async throws -> [[String: Any]] {
        try await call("GET", path)["data"] as? [[String: Any]] ?? []
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let config, let url = URL(string: "https://\(config.host)\(path)") else { throw ServiceFailure("Pair a Hue Bridge first") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.key, forHTTPHeaderField: "hue-application-key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceFailure("The Hue Bridge at \(config.host) did not answer: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 401 { throw ServiceFailure("The Hue Bridge no longer accepts this Mac’s key. Pair it again.") }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            let reason = ((json["errors"] as? [[String: Any]])?.first?["description"] as? String) ?? "status \(status)"
            throw ServiceFailure("Hue: \(reason)")
        }
        return json
    }

    // MARK: - Event stream

    private func listen() {
        stream?.cancel()
        guard let config, let url = URL(string: "https://\(config.host)/eventstream/clip/v2") else { return }
        stream = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                var request = URLRequest(url: url, timeoutInterval: 3600)
                request.setValue(config.key, forHTTPHeaderField: "hue-application-key")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                do {
                    guard let session = self?.streamSession, let trust = self?.trust else { return }
                    let (bytes, _) = try await session.bytes(for: request, delegate: trust)
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        guard let self else { return }
                        if self.watched.contains(where: { line.contains($0) }) { self.onChange?() }
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: 10_000_000_000) // the bridge restarted or the Wi-Fi dropped
            }
        }
    }
}

/// Trusts each Hue Bridge's self-signed certificate the first time, and only that
/// certificate afterwards.
final class BridgeTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String: String?] = [:]
    private var seen: [String: String] = [:]

    func pin(host: String, fingerprint: String?) {
        lock.lock(); defer { lock.unlock() }
        pins[Self.bare(host)] = .some(fingerprint)
    }

    func fingerprint(for host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return seen[Self.bare(host)]
    }

    /// "192.168.1.2:8443" → "192.168.1.2", "[fe80::1]:443" → "fe80::1": what TLS challenges name.
    static func bare(_ host: String) -> String {
        var value = host
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            value = String(host[host.index(after: host.startIndex)..<end])
        } else {
            let parts = host.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2 { value = String(parts[0]) }
        }
        // URL hosts encode a scoped IPv6 percent as %25; URLSession challenges may report %en11.
        if let scope = value.firstIndex(of: "%") { value = String(value[..<scope]) }
        if value.hasSuffix(".") { value.removeLast() }
        return value.lowercased()
    }

    // A streaming task (the event stream) asks its task-level delegate, the others the session's.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let key = Self.bare(host)
        let expected = pins[key]
        seen[key] = fingerprint
        lock.unlock()
        switch expected {
        case .none: completionHandler(.performDefaultHandling, nil) // not a bridge we know
        case .some(nil): completionHandler(.useCredential, URLCredential(trust: trust)) // pairing now
        case .some(let pinned?):
            let matches = pinned == fingerprint
            completionHandler(matches ? .useCredential : .cancelAuthenticationChallenge,
                              matches ? URLCredential(trust: trust) : nil)
        }
    }
}
