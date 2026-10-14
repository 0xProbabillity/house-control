import Foundation

/// A platform this device cannot reach itself, known from the list another device sent:
/// Apple Home on the Mac, as seen by the paired iPhone. Its devices can be linked in the
/// editor; they are switched from the iPhone, and stay simulated on the Mac.
@MainActor
public final class RemoteCatalogService: DeviceService {
    public let id: String
    public let title: String
    public var onChange: (() -> Void)?
    private let file: URL
    private var catalog: [String: Any]

    /// The catalog is cached in `file`, so the editor has it while the phone is away.
    public init(id: String, title: String, file: URL) {
        self.id = id
        self.title = title
        self.file = file
        catalog = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    public var isConnected: Bool { !(catalog["devices"] as? [[String: Any]] ?? []).isEmpty }
    public var controlsDevices: Bool { false }

    public var info: [String: Any] {
        ["connected": isConnected, "remote": true, "from": catalog["from"] as? String ?? "",
         "updated": catalog["updated"] as? Double ?? 0, "count": (catalog["devices"] as? [Any])?.count ?? 0]
    }

    /// Stores what `device` (the iPhone's name) reported.
    public func update(devices: [[String: Any]], from device: String) {
        catalog = ["devices": devices, "from": device, "updated": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: catalog) { try? data.write(to: file, options: .atomic) }
        onChange?()
    }

    public func devices() async throws -> [ServiceDevice] {
        (catalog["devices"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String,
                  let kind = DeviceKind(rawValue: d["kind"] as? String ?? "") else { return nil }
            var device = ServiceDevice(id: id, name: name, kind: kind, room: d["room"] as? String)
            device.online = d["online"] as? Bool ?? true
            device.capabilities = d["capabilities"] as? [String] ?? []
            if let lo = d.double("min"), let hi = d.double("max") { device.range = (lo, hi) }
            device.detail = d["detail"] as? String ?? ""
            return device
        }
    }

    public func read(_ ids: Set<String>) async throws -> [String: DeviceReading] { [:] }

    public func send(kind: DeviceKind, id: String, patch: [String: Any], state: [String: Any]) async throws {}

    public func disconnect() {
        catalog = [:]
        try? FileManager.default.removeItem(at: file)
    }
}
