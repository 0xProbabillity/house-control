import Foundation

/// A Homebridge server on the local network, through the REST API of its web UI
/// (homebridge-config-ui-x, port 8581 by default). Homebridge brings hundreds of brands into
/// HomeKit through its plugins; its accessories are HomeKit services, so lamps, plugs,
/// switches, heater-coolers, thermostats and thermometers map exactly as Apple Home's do.
///
/// The UI hands out a session token for a user name and password, valid for eight hours by
/// default, so the credentials are kept to sign in again when it runs out. Controlling
/// accessories needs Homebridge's "accessory control" (insecure mode, `-I`), which hb-service
/// turns on by default. The UI's socket.io channel tells the hub at once when something changes.
@MainActor
public final class HomebridgeService: DeviceService {
    public let id = "homebridge"
    public let title = "Homebridge"
    public var onChange: (() -> Void)?

    struct Config: Codable {
        /// "http://homebridge.local:8581": the UI's address.
        var url: String
        /// Nil when the UI has no sign-in (auth: none).
        var username: String?
        var password: String?
        var token: String?
        var name: String?
        var version: String?
        /// SHA-256 of the UI's certificate when it is served over HTTPS (self-signed as a rule):
        /// trusted on first use and checked ever after.
        var certificate: String?
        /// The account has two-factor sign-in: an expired session needs the owner again.
        var twoFactor: Bool?
    }

    /// The UI asked for the code from an authenticator app.
    public struct CodeRequired: LocalizedError {
        public var errorDescription: String? { "Enter the six-digit code from your authenticator app." }
    }

    /// The UI turned the kept user name and password down.
    public struct WrongCredentials: LocalizedError {
        public var errorDescription: String? { "Homebridge did not accept this user name and password (or the code)." }
    }

    private let vault: SecretStore
    private var config: Config?
    private let trust = BridgeTrust()
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var socketRetry: Task<Void, Never>?
    private var watched: Set<String> = []
    private var changePending = false
    /// The services from the last list, by uniqueId: what each can do and its last values.
    private var catalog: [String: Entry] = [:]
    /// Lamps last set to a white temperature (true) or a colour (false) from this app.
    private var whiteMode: [String: Bool] = [:]
    /// The sign-in in flight, shared by every request that found the session expired.
    private var signingIn: Task<String, Error>?
    /// Set when the session ran out and could not be renewed without the owner.
    public private(set) var needsSignIn = false

    public init(vault: SecretStore) {
        self.vault = vault
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        config = vault.read().flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        if let config {
            pinCertificate(config)
            listen()
        }
    }

    public var isConnected: Bool { config != nil }

    public var info: [String: Any] {
        guard let config else { return ["connected": false] }
        var out: [String: Any] = ["connected": true, "url": config.url, "name": config.name ?? "Homebridge",
                                  "version": config.version ?? "", "user": config.username ?? ""]
        if needsSignIn { out["expired"] = true }
        return out
    }

    /// For the paired devices: the Mac and its iPhones share the connection over their encrypted link.
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
        guard incoming.url != config?.url || incoming.username != config?.username || incoming.password != config?.password
                || incoming.token != config?.token || incoming.name != config?.name else { return }
        config = incoming
        needsSignIn = false
        vault.write(data)
        pinCertificate(incoming)
        catalog = [:]
        listen()
    }

    public func disconnect() {
        config = nil
        vault.write(nil)
        catalog = [:]
        needsSignIn = false
        socketRetry?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    public func watch(_ ids: Set<String>) { watched = ids }

    // MARK: - Connecting

    /// Checks the address, signs in (or takes the open session of a UI without sign-in),
    /// checks that accessories can be controlled, and keeps it all.
    /// Throws `CodeRequired` when the account has two-factor sign-in and `code` is empty.
    public func connect(url raw: String, username: String, password: String, code: String? = nil) async throws {
        let url = try Self.normalize(raw)
        var candidate = Config(url: url)
        if url.hasPrefix("https://"), let host = URL(string: url)?.host { trust.pin(host: host, fingerprint: nil) }
        let settings: [String: Any]
        do {
            settings = try await call("GET", "/api/auth/settings", config: candidate, signIn: false) as? [String: Any] ?? [:]
        } catch let failure as ServiceFailure where failure.message.contains("answered 404") {
            throw ServiceFailure("\(url) is not the Homebridge UI. Use the address you open Homebridge’s web page with (port 8581 by default).")
        }
        let env = settings["env"] as? [String: Any] ?? [:]
        guard env["homebridgeVersion"] != nil || env["packageName"] as? String == "homebridge-config-ui-x" else {
            throw ServiceFailure("\(url) answered, but not like the Homebridge UI.")
        }
        candidate.name = (env["homebridgeInstanceName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        candidate.version = env["homebridgeVersion"] as? String
        if let host = URL(string: url)?.host { candidate.certificate = trust.fingerprint(for: host) }

        let formAuth = settings["formAuth"] as? Bool ?? true
        if formAuth {
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !password.isEmpty else { throw ServiceFailure("Enter the user name and password you sign in to Homebridge with.") }
            candidate.username = user
            candidate.password = password
            let otp = code?.filter(\.isNumber)
            candidate.twoFactor = otp?.isEmpty == false
            candidate.token = try await signIn(candidate, code: otp)
        } else {
            candidate.token = try await signIn(candidate, code: nil)
        }

        // Without accessory control the list is refused: say how to turn it on.
        let list = try await call("GET", "/api/accessories", config: candidate, signIn: false) as? [[String: Any]] ?? []
        config = candidate
        needsSignIn = false
        vault.write(try? JSONEncoder().encode(candidate))
        remember(list)
        listen()
    }

    /// "homebridge.local" → "http://homebridge.local:8581".
    static func normalize(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ServiceFailure("Enter the address of your Homebridge, for example homebridge.local:8581") }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil, ["http", "https"].contains(url.scheme ?? "") else {
            throw ServiceFailure("“\(raw)” is not a web address")
        }
        if url.port == nil, url.scheme == "http" { s += ":8581" } // the UI's default port, which people leave out
        return s
    }

    private func pinCertificate(_ config: Config) {
        guard config.url.hasPrefix("https://"), let host = URL(string: config.url)?.host else { return }
        trust.pin(host: host, fingerprint: config.certificate)
    }

    /// A new session token: the user's sign-in, or the open session of a UI without one.
    private func signIn(_ config: Config, code: String?) async throws -> String {
        let answer: [String: Any]
        if let username = config.username {
            var body: [String: Any] = ["username": username, "password": config.password ?? ""]
            if let code, !code.isEmpty { body["otp"] = code }
            answer = try await call("POST", "/api/auth/login", body: body, config: config, signIn: false) as? [String: Any] ?? [:]
        } else {
            answer = try await call("POST", "/api/auth/noauth", config: config, signIn: false) as? [String: Any] ?? [:]
        }
        guard let token = answer["access_token"] as? String, !token.isEmpty else {
            throw ServiceFailure("Homebridge did not hand out a session.")
        }
        return token
    }

    /// The session ran out: sign in again with the kept credentials, once for every request
    /// that noticed. Two-factor accounts cannot be renewed without the owner.
    private func renewSession() async throws -> String {
        if let signingIn { return try await signingIn.value }
        guard let config else { throw ServiceFailure("Connect Homebridge first") }
        let task = Task { @MainActor () throws -> String in
            if config.twoFactor == true { throw CodeRequired() }
            return try await signIn(config, code: nil)
        }
        signingIn = task
        defer { signingIn = nil }
        do {
            let token = try await task.value
            self.config?.token = token
            if let current = self.config { vault.write(try? JSONEncoder().encode(current)) }
            needsSignIn = false
            return token
        } catch {
            // Only a refusal needs the owner; an unreachable Homebridge just retries later.
            if error is CodeRequired || error is WrongCredentials { needsSignIn = true }
            if error is CodeRequired {
                throw ServiceFailure("Homebridge asks for a two-factor code to sign in again. Connect it again under Connections → Homebridge.")
            }
            throw error
        }
    }

    // MARK: - Devices

    public func devices() async throws -> [ServiceDevice] {
        let list = try await call("GET", "/api/accessories") as? [[String: Any]] ?? []
        remember(list)
        return list.compactMap(Self.device(from:)).sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    public func read(_ ids: Set<String>) async throws -> [String: DeviceReading] {
        guard !ids.isEmpty else { return [:] }
        let list = try await call("GET", "/api/accessories") as? [[String: Any]] ?? []
        remember(list)
        var out: [String: DeviceReading] = [:]
        for id in ids {
            guard let entry = catalog[id] else { continue }
            out[id] = Self.reading(entry, whiteMode: whiteMode[id])
        }
        return out
    }

    public func send(kind: DeviceKind, id: String, patch: [String: Any], state: [String: Any]) async throws {
        if catalog[id] == nil { remember(try await call("GET", "/api/accessories") as? [[String: Any]] ?? []) }
        guard let entry = catalog[id] else { throw ServiceFailure("This device is no longer in Homebridge") }
        let has = Set(entry.types.keys)
        let writes = kind == .light
            ? HomeKitMapper.lightWrites(DeviceKind.withPower(patch, state: state), kind: entry.kind, has: has, limits: entry.limits)
            : HomeKitMapper.acWrites(patch, state: state, kind: entry.kind, has: has, limits: entry.limits)
        if patch["temp"] != nil { whiteMode[id] = true }
        if patch["color"] is String { whiteMode[id] = false }
        for (name, value) in writes {
            guard let type = entry.types[name] else { continue }
            let path = "/api/accessories/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
            let updated = try await call("PUT", path, body: ["characteristicType": type, "value": value])
            if let service = updated as? [String: Any], let fresh = Self.entry(from: service) { catalog[id] = fresh }
        }
    }

    // MARK: - Mapping

    /// One HomeKit service as Homebridge's UI lists it, in the terms of `HomeKitMapper`.
    struct Entry {
        var kind: HomeKitMapper.Kind
        /// Short name ("on", "brightness"…) → the characteristic's HomeKit type name ("On").
        var types: [String: String]
        var values: [String: Any]
        var limits: [String: (Double, Double)]
        /// The target-state values an AC accepts, when it says.
        var validModes: [Int]?
    }

    static func entry(from service: [String: Any]) -> Entry? {
        guard let uuid = service["uuid"] as? String, let kind = HomeKitMapper.kind(ofService: uuid) else { return nil }
        var entry = Entry(kind: kind, types: [:], values: [:], limits: [:])
        for c in service["serviceCharacteristics"] as? [[String: Any]] ?? [] {
            guard let uuid = c["uuid"] as? String, let name = HomeKitMapper.name(ofCharacteristic: uuid),
                  let type = c["type"] as? String else { continue }
            entry.types[name] = type
            if let value = c["value"], !(value is NSNull) { entry.values[name] = value }
            if let lo = c.double("minValue"), let hi = c.double("maxValue") { entry.limits[name] = (lo, hi) }
            if name == "targetState" || name == "targetHeatingCooling" {
                entry.validModes = (c["validValues"] as? [NSNumber])?.map(\.intValue)
            }
        }
        return entry
    }

    static func device(from service: [String: Any]) -> ServiceDevice? {
        guard let id = service["uniqueId"] as? String, let entry = entry(from: service) else { return nil }
        let information = service["accessoryInformation"] as? [String: Any] ?? [:]
        let name = (service["serviceName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? information["Name"] as? String ?? "Homebridge device"
        var device = ServiceDevice(id: id, name: name, kind: entry.kind.device)
        if entry.kind == .light { device.capabilities = HomeKitMapper.capabilities(Set(entry.types.keys)) }
        if entry.kind.device == .ac {
            let key = entry.kind == .thermostat ? "targetTemperature" : "coolingThreshold"
            if let range = entry.limits[key] { device.range = range }
        }
        let maker = (information["Manufacturer"] as? String).flatMap { $0.isEmpty ? nil : "\($0) · " } ?? ""
        let what = service["humanType"] as? String ?? service["type"] as? String ?? entry.kind.rawValue
        device.detail = maker + what.lowercased()
        return device
    }

    static func reading(_ entry: Entry, whiteMode: Bool? = nil) -> DeviceReading {
        switch entry.kind {
        case .light, .outlet:
            return DeviceReading(light: HomeKitMapper.lightState(entry.values, whiteMode: whiteMode))
        case .heaterCooler, .thermostat:
            return DeviceReading(ac: HomeKitMapper.acState(entry.values, kind: entry.kind),
                                 features: HomeKitMapper.acFeatures(kind: entry.kind, has: Set(entry.types.keys), validModes: entry.validModes))
        case .sensor:
            return DeviceReading(temperature: entry.values.double("currentTemperature"))
        }
    }

    private func remember(_ list: [[String: Any]]) {
        var fresh: [String: Entry] = [:]
        for service in list {
            guard let id = service["uniqueId"] as? String, let entry = Self.entry(from: service) else { continue }
            fresh[id] = entry
        }
        if !fresh.isEmpty || list.isEmpty { catalog = fresh }
    }

    // MARK: - HTTP

    /// `signIn`: on an expired session, sign in again and repeat the request once.
    private func call(_ method: String, _ path: String, body: [String: Any]? = nil,
                      config given: Config? = nil, signIn: Bool = true) async throws -> Any? {
        guard let config = given ?? self.config, let url = URL(string: config.url + path) else {
            throw ServiceFailure("Connect Homebridge first")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = config.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceFailure("Homebridge at \(config.url) did not answer: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        let message = ((json as? [String: Any])?["message"] as? String) ?? ""
        switch status {
        case 200..<300:
            return json
        case 401 where signIn && given == nil:
            _ = try await renewSession()
            return try await call(method, path, body: body, signIn: false)
        case 401:
            throw ServiceFailure("Homebridge ended the session. Connect it again under Connections → Homebridge.")
        case 412 where path == "/api/auth/login":
            throw CodeRequired()
        case 403 where path == "/api/auth/login":
            throw WrongCredentials()
        case 403 where path == "/api/auth/noauth":
            throw ServiceFailure("This Homebridge asks for a sign-in. Enter your user name and password.")
        case 429:
            throw ServiceFailure("Homebridge refuses sign-ins for a while after several wrong attempts. Wait a few minutes and try again.")
        case 400 where message.localizedCaseInsensitiveContains("insecure"):
            throw ServiceFailure("Homebridge does not allow controlling accessories yet. In its web page open Settings → Startup & Environment, turn on “Enable UI Accessory Control (-I)” and restart Homebridge.")
        case 404:
            throw ServiceFailure("Homebridge does not know \(path). Update the Homebridge UI plugin.")
        default:
            let text = message.isEmpty ? String(data: data, encoding: .utf8)?.prefix(200).description ?? "" : message
            throw ServiceFailure("Homebridge answered \(status) \(text)")
        }
    }

    // MARK: - Live updates

    /// The UI's socket.io channel (Engine.IO 4 over a WebSocket): `get-accessories` starts its
    /// characteristic monitor, then every change arrives as `accessories-data` with the services
    /// it touched. Only changes to the watched services reach `onChange`.
    private func listen() {
        socketRetry?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        guard let config, let token = config.token, var parts = URLComponents(string: config.url + "/socket.io/") else { return }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [.init(name: "EIO", value: "4"), .init(name: "transport", value: "websocket"), .init(name: "token", value: token)]
        guard let url = parts.url else { return }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 32 << 20 // the first message lists every accessory
        socket = task
        task.resume()
        Task { @MainActor [weak self] in await self?.run(task) }
    }

    private func run(_ task: URLSessionWebSocketTask) async {
        var quietUntil = Date.distantFuture // the full lists sent right after joining are not changes
        var refused = false
        do {
            while task === socket {
                guard case .string(let frame) = try await task.receive() else { continue }
                if frame == "2" { try await task.send(.string("3")); continue }              // ping → pong
                if frame.hasPrefix("0{") { try await task.send(.string("40/accessories,")); continue }
                if frame.hasPrefix("40/accessories") {
                    try await task.send(.string("42/accessories,[\"get-accessories\"]"))
                    quietUntil = Date().addingTimeInterval(5)
                    continue
                }
                if frame.hasPrefix("44/accessories") || frame.hasPrefix("41/accessories") { refused = true; break }
                guard frame.hasPrefix("42/accessories,[\"accessories-data\""), Date() > quietUntil,
                      !changePending, watched.contains(where: { frame.contains($0) }) else { continue }
                // A burst of changes (a scene) becomes one read.
                changePending = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    self?.changePending = false
                    self?.onChange?()
                }
            }
        } catch {}
        guard task === socket, config != nil else { return }
        socket = nil
        socketRetry = Task { @MainActor [weak self] in
            // Refused: most likely the session ran out. Otherwise Homebridge restarted or the Wi-Fi dropped.
            if refused { _ = try? await self?.renewSession() }
            try? await Task.sleep(nanoseconds: refused ? 2_000_000_000 : 10_000_000_000)
            guard !Task.isCancelled, self?.needsSignIn == false else { return }
            self?.listen()
        }
    }
}
