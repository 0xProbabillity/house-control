import Foundation

/// The cloud behind the plan's `tuya` links (Smart Life). It is an optional part of the
/// apps, the HouseSmartLife module: a build without it keeps such links in the plan but
/// shows those devices as simulated.
@MainActor
public protocol LinkedCloud: AnyObject {
    /// True when an account is connected and commands can be sent.
    var isConnected: Bool { get }
    /// What the editor and the settings show for it, under "smartlife".
    var info: [String: Any] { get }
    /// Sends the panel's change (`patch`; `state` is the device with it applied) to the
    /// device a plan's `tuya` link names. Throws `CommandRejection` when part of it did not
    /// reach the device.
    func command(appId: String, kind: String, link: [String: Any], patch: [String: Any],
                 state: [String: Any], log: EventLog) async throws
    /// What the linked devices report (app device id -> its `tuya` link), in the shape the
    /// panel's `applyRemote` takes; nil when the cloud could not be reached.
    func poll(_ links: [String: (kind: String, link: [String: Any])]) async -> [String: Any]?
    /// Every device of the account, in the editor's terms.
    func devices() async throws -> [[String: Any]]
}

/// The parts of a change that did not reach the device; the panel rolls back only those.
public struct CommandRejection: Error {
    public let message: String
    public let fields: [String]

    public init(message: String, fields: [String]) {
        self.message = message
        self.fields = fields
    }
}
