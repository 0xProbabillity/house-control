import Foundation
import Network

/// The Mac's side of the sync: advertises itself on the local network and hands its
/// floor plan to the iPhones that were paired with it. Nothing listens until the user
/// pairs a phone for the first time.
@MainActor
public final class SyncServer {
    private let store: SecretStore
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var advertise = true
    public private(set) var pairing: SyncPairing?
    /// True once Bonjour confirmed that phones can find this Mac. It stays false when
    /// macOS has not been allowed to let the app use the local network.
    public private(set) var isAdvertised = false

    private final class Peer {
        let channel: SyncChannel
        var name = ""
        /// The plan revision this iPhone is known to hold.
        var revision = ""
        init(_ channel: SyncChannel) { self.channel = channel }
    }

    /// What to send: read every time a phone connects or `broadcast()` is called.
    public var snapshot: (() -> SyncState)?
    /// Called when a phone connects or disconnects.
    public var onPeersChanged: (() -> Void)?
    /// A phone asks the Mac to display the QR code of its own Smart Life login
    /// (`content`), or to take it down again (nil). The second argument is the phone's name.
    /// A phone that disconnects does not take its code down: it is scanned from another
    /// app on that phone, and iOS cuts the connection as soon as ours leaves the screen.
    public var onShowQR: ((String?, String) -> Void)?
    /// A phone sends the devices of its Apple Home (which only it can reach), for the editor.
    public var onCatalog: (([[String: Any]], String) -> Void)?
    /// A phone sends the floor plan it edited (the file byte for byte, already checked to be
    /// a plan) and its name. The Mac stores it and calls `broadcast()`.
    public var onPlan: ((Data, String) -> Void)?
    /// A phone sends its Home Assistant and Hue connections (see `DeviceHub.adoptConnections`)
    /// and the Smart Life User Code it signed in with, if any.
    public var onConnections: (([String: Any], String, String) -> Void)?

    /// `store` keeps the pairing (by default `sync.json` next to the plan, readable by its user only).
    public init(store: SecretStore) {
        self.store = store
        pairing = store.read().flatMap { try? JSONDecoder().decode(SyncPairing.self, from: $0) }
    }

    public var isEnabled: Bool { pairing != nil }
    /// Names of the iPhones connected right now.
    public var connectedDevices: [String] { peers.values.map(\.name).filter { !$0.isEmpty }.sorted() }
    /// The port the listener got, once it is running.
    public var port: UInt16? { listener?.port?.rawValue }

    /// Makes sure this Mac can be paired with and returns what the phone has to scan.
    @discardableResult
    public func enable(name: String) -> SyncPairing {
        guard var current = pairing else { return reset(name: name) }
        if current.name != name {
            // The Mac was renamed: same key, new name on the network and in the code.
            current.name = name
            pairing = current
            store.write(try? JSONEncoder().encode(current))
            restart()
        } else {
            start()
        }
        return current
    }

    /// New key: every phone paired so far has to be paired again.
    @discardableResult
    public func reset(name: String) -> SyncPairing {
        let fresh = SyncPairing.generate(name: name)
        pairing = fresh
        store.write(try? JSONEncoder().encode(fresh))
        restart()
        return fresh
    }

    public func disable() {
        pairing = nil
        store.write(nil)
        stop()
    }

    /// Starts listening if this Mac has been paired with before. `advertise: false` skips
    /// Bonjour, for tests that connect to the port directly.
    public func start(advertise: Bool = true) {
        self.advertise = advertise
        guard let pairing, listener == nil else { return }
        guard let listener = try? NWListener(using: SyncTransport.parameters(key: pairing.key)) else { return }
        if advertise {
            var txt = NWTXTRecord()
            txt["id"] = pairing.id
            listener.service = NWListener.Service(name: pairing.name, type: SyncTransport.serviceType, txtRecord: txt)
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                MainActor.assumeIsolated {
                    guard let self, case .add = change, !self.isAdvertised else { return }
                    self.isAdvertised = true
                    self.onPeersChanged?()
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                // A listener that failed (network change, port lost) is replaced.
                guard let self, case .failed = state else { return }
                self.listener?.cancel()
                self.listener = nil
                self.isAdvertised = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start(advertise: self.advertise) }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isAdvertised = false
        for peer in peers.values { peer.channel.close() }
        peers = [:]
        onPeersChanged?()
    }

    private func restart() {
        stop()
        start(advertise: advertise)
    }

    /// Sends the current state to every connected phone (after the plan was saved, or the
    /// Smart Life account changed).
    public func broadcast() {
        guard let state = snapshot?() else { return }
        for peer in peers.values where !peer.name.isEmpty { send(state, to: peer) }
    }

    private func send(_ state: SyncState, to peer: Peer) {
        peer.channel.send(state.message(includingPlan: state.revision != peer.revision))
        peer.revision = state.revision
    }

    private func accept(_ connection: NWConnection) {
        let channel = SyncChannel(connection)
        let peer = Peer(channel)
        let key = ObjectIdentifier(channel)
        peers[key] = peer
        channel.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.handle(message, from: peer)
        }
        channel.onClose = { [weak self] _ in
            guard let self, let gone = self.peers.removeValue(forKey: key) else { return }
            if !gone.name.isEmpty { self.onPeersChanged?() }
        }
        channel.start()
    }

    private func handle(_ message: [String: Any], from peer: Peer) {
        switch message["type"] as? String {
        case "hello":
            let isNew = peer.name.isEmpty
            peer.name = (message["device"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
            peer.revision = message["rev"] as? String ?? ""
            if let state = snapshot?() { send(state, to: peer) }
            if isNew { onPeersChanged?() }
        case "showQR":
            guard !peer.name.isEmpty else { return }
            onShowQR?(message["content"] as? String, peer.name)
        case "catalog":
            guard !peer.name.isEmpty, let devices = message["devices"] as? [[String: Any]] else { return }
            onCatalog?(devices, peer.name)
        case "plan":
            guard !peer.name.isEmpty, let text = message["plan"] as? String else { return }
            let data = Data(text.utf8)
            guard (try? PlanStore.validate(data)) != nil else { return }
            // The phone holds this revision now: the broadcast that follows need not echo it.
            peer.revision = PlanStore.revision(of: data)
            onPlan?(data, peer.name)
        case "connections":
            guard !peer.name.isEmpty, let shared = message["connections"] as? [String: Any] else { return }
            onConnections?(shared, message["userCode"] as? String ?? "", peer.name)
        default:
            break
        }
    }
}
