import Foundation
import Network
import dnssd

/// The iPhone's side of the sync: finds the paired Mac on the local network, stays
/// connected while the app is open and receives the floor plan whenever it changes.
@MainActor
public final class SyncClient {
    public enum Status: Equatable {
        /// No Mac has been paired yet.
        case unpaired
        /// Looking for the Mac on this network.
        case searching
        case connecting
        case connected
        /// The Mac was found but would not talk to us; the text says why.
        case failed(String)
    }

    private let store: SecretStore
    public private(set) var pairing: SyncPairing?
    public private(set) var status: Status = .unpaired
    private var running = false
    private var browser: NWBrowser?
    private var channel: SyncChannel?
    private var retry: DispatchWorkItem?
    /// What the Mac should be showing for this phone, and whether it has been told yet.
    private var qrContent: String?
    private var qrUnsent = false
    /// This phone's Apple Home devices, waiting to be sent to the Mac.
    private var catalog: [[String: Any]]?
    /// This phone's Home Assistant and Hue connections and Smart Life User Code, waiting to be
    /// sent to the Mac.
    private var connections: (shared: [String: Any], userCode: String)?
    /// Set to connect straight to a host and port instead of browsing (tests).
    var fixedEndpoint: NWEndpoint?

    /// This device's name as the Mac shows it.
    public var deviceName = "iPhone"
    /// The revision of the plan this device already holds, so the Mac need not resend it.
    public var planRevision: (() -> String?)?
    public var onStatus: (() -> Void)?
    public var onState: ((SyncState) -> Void)?

    public init(store: SecretStore) {
        self.store = store
        pairing = store.read().flatMap { try? JSONDecoder().decode(SyncPairing.self, from: $0) }
        status = pairing == nil ? .unpaired : .searching
        // HOUSE_SYNC_ENDPOINT=host:port skips the search and connects there (a simulator
        // talking to a Mac whose Bonjour advertisement is not allowed, for instance).
        if let fixed = ProcessInfo.processInfo.environment["HOUSE_SYNC_ENDPOINT"]?.split(separator: ":"), fixed.count == 2,
           let port = NWEndpoint.Port(String(fixed[1])) {
            fixedEndpoint = .hostPort(host: NWEndpoint.Host(String(fixed[0])), port: port)
        }
    }

    public var isPaired: Bool { pairing != nil }
    public var isConnected: Bool { status == .connected }

    public func pair(_ new: SyncPairing) {
        teardown()
        pairing = new
        store.write(try? JSONEncoder().encode(new))
        set(.searching)
        if running { search() }
    }

    public func unpair() {
        qrContent = nil
        qrUnsent = false
        teardown()
        pairing = nil
        store.write(nil)
        set(.unpaired)
    }

    /// Call when the app comes to the foreground.
    public func start() {
        guard !running else { return }
        running = true
        if pairing != nil { search() }
    }

    /// Call when the app goes to the background.
    public func stop() {
        running = false
        teardown()
        if pairing != nil { set(.searching) }
    }

    /// Asks the Mac for its current state again.
    public func refresh() {
        guard running, pairing != nil else { return }
        if let channel, status == .connected { hello(on: channel) } else { teardown(); search() }
    }

    /// Asks the Mac to display `content` as a QR code (nil takes it down again). Used for
    /// the Smart Life login, which has to be scanned by the Smart Life app on this phone.
    /// Returns false when the Mac is not connected right now; the request is then delivered
    /// as soon as it is. (The code is scanned from another app, so this one is in the
    /// background, and disconnected, for most of the time the code is up.)
    @discardableResult
    public func showQR(_ content: String?) -> Bool {
        qrContent = content
        qrUnsent = true
        return flushQR()
    }

    /// Hands the Mac this phone's Apple Home devices (the Mac cannot see Apple Home itself),
    /// now or as soon as it is connected.
    public func sendCatalog(_ devices: [[String: Any]]) {
        catalog = devices
        flushCatalog()
    }

    /// Hands the Mac this phone's connections, now or as soon as it is connected. The Mac
    /// keeps whichever side changed a platform last.
    public func sendConnections(_ shared: [String: Any], userCode: String) {
        connections = (shared, userCode)
        flushConnections()
    }

    private func flushConnections() {
        guard let connections, let channel, status == .connected else { return }
        channel.send(["type": "connections", "connections": connections.shared, "userCode": connections.userCode])
        self.connections = nil
    }

    /// Sends a floor plan edited on this phone to the Mac (the file byte for byte, so both
    /// sides compute the same revision). Not queued: false when the Mac is not connected
    /// right now, and the next state it sends decides what happens to the edit.
    @discardableResult
    public func sendPlan(_ data: Data) -> Bool {
        guard let channel, status == .connected, let text = String(data: data, encoding: .utf8) else { return false }
        channel.send(["type": "plan", "plan": text])
        return true
    }

    private func flushCatalog() {
        guard let catalog, let channel, status == .connected else { return }
        channel.send(["type": "catalog", "devices": catalog])
        self.catalog = nil
    }

    private func flushQR() -> Bool {
        guard qrUnsent, let channel, status == .connected else { return false }
        var message: [String: Any] = ["type": "showQR"]
        if let qrContent { message["content"] = qrContent }
        channel.send(message)
        qrUnsent = false
        return true
    }

    // MARK: - Connection

    private func set(_ new: Status) {
        guard new != status else { return }
        status = new
        onStatus?()
    }

    private func teardown() {
        retry?.cancel()
        retry = nil
        browser?.cancel()
        browser = nil
        channel?.onClose = nil
        channel?.close()
        channel = nil
    }

    private func search() {
        guard running, let pairing, channel == nil else { return }
        if let fixedEndpoint {
            connect(to: fixedEndpoint, pairing)
            return
        }
        guard browser == nil else { return }
        if case .failed = status {} else { set(.searching) }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SyncTransport.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.channel == nil, let pairing = self.pairing else { return }
                let match = results.first { result in
                    if case .bonjour(let txt) = result.metadata, txt["id"] == pairing.id { return true }
                    return false
                }
                if let match { self.connect(to: match.endpoint, pairing) }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failed = state { self.scheduleRetry() }
                // No permission to use the local network: say so instead of searching forever.
                if case .waiting(let error) = state, case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                    self.set(.failed("Allow House Control to use the local network in Settings → Privacy & Security → Local Network."))
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func connect(to endpoint: NWEndpoint, _ pairing: SyncPairing) {
        browser?.cancel()
        browser = nil
        set(.connecting)
        let channel = SyncChannel(NWConnection(to: endpoint, using: SyncTransport.parameters(key: pairing.key)))
        self.channel = channel
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.hello(on: channel)
        }
        channel.onMessage = { [weak self] message in
            guard let self, let state = SyncState(message: message) else { return }
            self.set(.connected)
            _ = self.flushQR()
            self.flushCatalog()
            self.flushConnections()
            self.onState?(state)
        }
        channel.onClose = { [weak self] error in
            guard let self else { return }
            self.channel = nil
            // The handshake fails when the Mac's key was reset since this phone was paired.
            if case .some(.tls) = error {
                self.set(.failed("\(pairing.name) did not accept this pairing. Pair again from the Mac's menu: Pair iPhone…"))
            } else if self.running {
                self.set(.searching)
            }
            self.scheduleRetry()
        }
        channel.start()
    }

    private func hello(on channel: SyncChannel) {
        channel.send(["type": "hello", "device": deviceName, "rev": planRevision?() ?? ""])
    }

    private func scheduleRetry() {
        guard running, pairing != nil else { return }
        retry?.cancel()
        browser?.cancel()
        browser = nil
        let work = DispatchWorkItem { [weak self] in self?.search() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
