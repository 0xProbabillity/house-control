import Foundation
import Observation
import HouseCore

/// One explicit plan authority at a time. Device credentials remain independent.
@MainActor @Observable
final class ServerSync {
    private(set) var enabled: Bool
    private(set) var address: String
    private(set) var status = "Not connected"
    private(set) var busy = false
    private(set) var conflict = false
    @ObservationIgnored private let secret: SecretStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var transport: ((String, [String: Any]?) async throws -> [String: Any])?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var foreground = false
    private(set) var editorOpen = false
    @ObservationIgnored private var remote: [String: Any]?
    @ObservationIgnored private var remoteRevision: Any?
    @ObservationIgnored var local: (() -> [String: Any]?)?
    @ObservationIgnored var adopt: (([String: Any]) throws -> Void)?
    @ObservationIgnored var backup: (([String: Any]) throws -> Void)?
    @ObservationIgnored var modeChanged: (() -> Void)?
    @ObservationIgnored private var pending = false
    private var baseline: String? {
        get { defaults.string(forKey: "sharedServerBaseline") }
        set { defaults.set(newValue, forKey: "sharedServerBaseline") }
    }
    init(secret: SecretStore, defaults: UserDefaults = .standard) {
        self.secret = secret
        self.defaults = defaults
        address = defaults.string(forKey: "sharedServerAddress") ?? ""
        enabled = defaults.bool(forKey: "sharedServerEnabled")
    }
    static func validAddress(_ value: String) throws -> URL {
        guard let c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host?.lowercased(), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/",
              c.port == nil || (1...65535).contains(c.port!),
              c.scheme == "https" || (c.scheme == "http" && privateHost(host)), let url = c.url else {
            throw Failure("Use an HTTPS address, or HTTP on a private IP, localhost or .local host. Do not include a path, password or token.")
        }
        return url
    }
    private static func privateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host == "[::1]" || host == "::1" { return true }
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80:") { return h.contains(":") }
        let n = h.split(separator: ".").compactMap { Int($0) }
        guard n.count == 4, n.allSatisfy({ (0...255).contains($0) }) else { return false }
        return n[0] == 10 || n[0] == 127 || (n[0] == 192 && n[1] == 168) || (n[0] == 172 && (16...31).contains(n[1]))
    }
    func connect(address value: String, token: String) throws {
        guard !busy else { throw Failure("Wait for the current sync to finish.") }
        let url = try Self.validAddress(value)
        let clean = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean != address {
            guard !token.isEmpty else { throw Failure("Enter this server’s access token when changing its address.") }
            baseline = nil
        }
        if !token.isEmpty { secret.write(Data(token.utf8)) }
        guard let saved = secret.read(), !saved.isEmpty else { throw Failure("Enter the server access token.") }
        address = clean; enabled = true; conflict = false; remote = nil; remoteRevision = nil
        defaults.set(address, forKey: "sharedServerAddress")
        defaults.set(true, forKey: "sharedServerEnabled")
        modeChanged?()
        startPolling()
        Task { await synchronize() }
    }
    func useMacMode() {
        guard !busy else { return }
        enabled = false; conflict = false; status = "Mac / local mode"
        pollTask?.cancel(); pollTask = nil
        defaults.set(false, forKey: "sharedServerEnabled")
        modeChanged?()
    }
    func setActive(_ active: Bool) {
        foreground = active
        pollTask?.cancel(); pollTask = nil
        if active { startPolling() }
    }
    private func startPolling() {
        guard foreground, enabled, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronize()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
    }
    func beginEditing() { editorOpen = true }
    func endEditing() { editorOpen = false; if enabled { Task { await synchronize() } } }
    func localChanged() {
        guard enabled else { return }
        if busy { pending = true; return }
        Task { await synchronize(publishingDraft: true) }
    }
    func synchronize(publishingDraft: Bool = false) async {
        guard enabled, !busy, !conflict, !editorOpen || publishingDraft else { return }
        busy = true; status = "Syncing…"
        defer {
            busy = false
            if pending { pending = false; localChanged() }
        }
        do {
            let response = try await request(method: "GET")
            guard let config = response["config"] as? [String: Any], let revision = response["revision"] else { throw Failure("The server did not return a floor plan and revision.") }
            _ = try PlanStore.validate(PlanStore.encode(config))
            let theirs = try hash(config)
            let localConfig = local?()
            let ours = try localConfig.map { try hash($0) }
            if ours == theirs { baseline = theirs; status = "Connected · up to date"; return }
            if ours == nil || ours == baseline {
                // An editor may have opened while GET was in flight. Never advance its
                // baseline under an unsaved draft; the save must see the older baseline.
                guard !editorOpen || publishingDraft else { return }
                try adopt?(config); baseline = theirs; status = "Updated from shared server"
            } else if theirs == baseline, let config = local?() {
                try await publish(config, expected: revision)
            } else {
                remote = config; remoteRevision = revision; conflict = true
                status = "Both homes differ. Choose which plan to keep in Shared server settings."
            }
        } catch { status = "Not synced: \(error.localizedDescription)" }
    }
    /// A conflict never overwrites either side automatically; archive the displaced plan.
    func resolve(keepPhone: Bool) async {
        guard enabled, !busy, conflict, let config = remote, let revision = remoteRevision else { return }
        guard !editorOpen else { status = "Close the editor before choosing which plan to keep."; return }
        busy = true
        defer { busy = false }
        do {
            if keepPhone, let ours = local?() {
                try backup?(config)
                try await publish(ours, expected: revision)
            } else {
                if let ours = local?() { try backup?(ours) }
                try adopt?(config); baseline = try hash(config); status = "Updated from shared server"
            }
            remote = nil; remoteRevision = nil; conflict = false
            // A fetch checks for a newer server edit after the choice.
            pending = false
            Task { await synchronize() }
        } catch {
            // A stale write requires fetching and reviewing the new remote version.
            conflict = false; remote = nil; remoteRevision = nil
            status = "Not synced: \(error.localizedDescription) Tap Sync now to review the latest plan."
        }
    }
    private func publish(_ config: [String: Any], expected: Any) async throws {
        _ = try await request(method: "PUT", body: ["config": config, "expectedRevision": expected])
        baseline = try hash(config); status = "Connected · up to date"
    }
    private func hash(_ config: [String: Any]) throws -> String { PlanStore.revision(of: try PlanStore.encode(config)) }
    private func request(method: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        if let transport { return try await transport(method, body) }
        let base = try Self.validAddress(address)
        guard let token = secret.read().flatMap({ String(data: $0, encoding: .utf8) }), !token.isEmpty else { throw Failure("Enter the server access token again.") }
        var request = URLRequest(url: base.appendingPathComponent("api/plan"))
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        // Redirects are refused so a different origin can never receive the token.
        let session = URLSession(configuration: configuration, delegate: NoServerRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure("No server response.") }
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 409 { throw Failure("The server plan changed. Your iPhone plan is saved here; review the latest server plan before retrying.") }
            if response.statusCode == 401 { throw Failure("The server rejected this access token.") }
            throw Failure("Server request failed (\(response.statusCode)).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("Invalid server response.") }
        return json
    }
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
private final class NoServerRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
