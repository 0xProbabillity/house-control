import Foundation
import Network
import CryptoKit

/// What an iPhone needs to find its Mac and talk to it: shown by the Mac as a QR code
/// (or copied as a link) once, kept in the Keychain afterwards.
public struct SyncPairing: Codable, Equatable {
    /// Identifies the Mac among the ones advertising on the network.
    public var id: String
    /// The Mac's name, for display.
    public var name: String
    /// 32 random bytes; both sides derive the connection's pre-shared key from it.
    public var key: Data

    public init(id: String, name: String, key: Data) {
        self.id = id
        self.name = name
        self.key = key
    }

    public static func generate(name: String) -> SyncPairing {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return SyncPairing(id: UUID().uuidString.lowercased(), name: name, key: Data(bytes))
    }

    public static let scheme = "housecontrol"

    /// `housecontrol://pair?v=1&id=…&name=…&key=…` — the content of the pairing QR code.
    public var link: String {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "key", value: Self.base64URL(key)),
        ]
        return c.string ?? ""
    }

    /// Reads a pairing link; nil for anything that is not one.
    public init?(link: String) {
        guard let c = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == Self.scheme, c.host == "pair" else { return nil }
        let items = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard items["v"] == "1", let id = items["id"], !id.isEmpty,
              let key = items["key"].flatMap(Self.data(base64URL:)), key.count == 32 else { return nil }
        self.init(id: id, name: items["name"] ?? "Mac", key: key)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// What the Mac tells a paired iPhone.
public struct SyncState {
    public var macName: String
    /// Fingerprint of the Mac's own floor plan; empty when it only has the demo plans.
    public var revision: String
    /// The plan file byte for byte. Nil when the iPhone already holds `revision`.
    public var plan: Data?
    /// The Smart Life "User Code" entered on the Mac, to save typing it on the phone.
    /// It identifies the account; it is not a credential.
    public var userCode: String
    public var smartLifeConnected: Bool
    /// The Mac's Home Assistant and Hue connections (address and token / bridge key), so the
    /// phone controls the same devices without setting anything up. Only ever sent over this
    /// channel, which nothing but a paired phone can open. Nil from a Mac that predates them.
    public var connections: [String: Any]?

    public init(macName: String, revision: String, plan: Data?, userCode: String, smartLifeConnected: Bool,
                connections: [String: Any]? = nil) {
        self.macName = macName
        self.revision = revision
        self.plan = plan
        self.userCode = userCode
        self.smartLifeConnected = smartLifeConnected
        self.connections = connections
    }

    func message(includingPlan: Bool) -> [String: Any] {
        var out: [String: Any] = ["type": "state", "mac": macName, "rev": revision,
                                  "userCode": userCode, "smartLife": smartLifeConnected]
        if includingPlan, let plan, let text = String(data: plan, encoding: .utf8) { out["plan"] = text }
        if let connections { out["connections"] = connections }
        return out
    }

    init?(message: [String: Any]) {
        guard message["type"] as? String == "state" else { return nil }
        self.init(macName: message["mac"] as? String ?? "Mac",
                  revision: message["rev"] as? String ?? "",
                  plan: (message["plan"] as? String).map { Data($0.utf8) },
                  userCode: message["userCode"] as? String ?? "",
                  smartLifeConnected: message["smartLife"] as? Bool ?? false,
                  connections: message["connections"] as? [String: Any])
    }
}

enum SyncTransport {
    static let serviceType = "_housecontrol._tcp"
    static let maxFrame = 8 * 1024 * 1024

    /// TLS 1.2 with a pre-shared key and nothing else: a peer that does not hold the
    /// pairing key cannot complete the handshake, in either direction.
    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let derived = HMAC<SHA256>.authenticationCode(for: Data("HouseControl sync v1".utf8), using: SymmetricKey(data: key))
        let psk = derived.withUnsafeBytes { DispatchData(bytes: $0) }
        let hint = Data("housecontrol".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, hint as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}

/// JSON messages over one connection, each prefixed with its length (4 bytes, big endian).
/// Everything happens on the main queue.
@MainActor
final class SyncChannel {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    /// Called once, with the error that ended the connection if there was one.
    var onClose: ((NWError?) -> Void)?
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.onReady?()
                    self.receiveHeader()
                case .failed(let error): self.finish(error)
                case .waiting(let error): self.finish(error) // no route / refused: let the owner retry
                case .cancelled: self.finish(nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: [String: Any]) {
        guard !closed, let body = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        var frame = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        connection.cancel()
    }

    private func finish(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(error)
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard let data, data.count == 4, error == nil else { self.finish(error); return }
                let length = Int(data.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard length > 0, length <= SyncTransport.maxFrame, !isComplete else { self.finish(nil); return }
                self.receiveBody(length)
            }
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard let data, data.count == length, error == nil else { self.finish(error); return }
                if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.onMessage?(message)
                }
                self.receiveHeader()
            }
        }
    }
}
