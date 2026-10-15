import Foundation
import HouseCore

/// Drives air conditioners that are a remote control learned by an infrared blaster.
///
/// Such an AC is not a device with a state of its own. Tuya keeps a virtual remote in
/// the cloud; every change is one key press (`PowerOn`, `PowerOff`, `M`, `T`, `F`) that
/// the blaster transmits, and the cloud works out the infrared code from the state it
/// remembers for that remote. Three things follow:
///  - keys go out one at a time, a second apart (several in one request are refused);
///  - nothing is transmitted while the AC is off: what changed is sent when it is switched on;
///  - when a key is refused (code 2008) the cloud's idea of the remote usually differs
///    from ours, e.g. it is in a mode with a fixed temperature. The rest of our state is
///    replayed once and the key retried.
@MainActor
final class InfraredRemote {
    struct Rejection: Error {
        let message: String
        /// The parts of the change that did not reach the AC.
        let fields: [String]
    }

    /// Seconds between two key presses of the same remote.
    var spacing: TimeInterval = 1.0
    private static let fields = ["on", "mode", "target", "fan"]
    private var lastKey: [String: Date] = [:]
    /// Settings changed while the AC was off, to be sent along when it is switched on.
    private var deferred: [String: Set<String>] = [:]

    /// Brings the remote `deviceId` from where it was to `state` (the app's state with
    /// `patch` already applied). `send` transmits one command; `note` receives log lines.
    func apply(patch: [String: Any], state: [String: Any], to deviceId: String,
               send: ([String: Any]) async throws -> Void, note: (String) -> Void) async throws {
        let isOn = state["on"] as? Bool ?? false
        var wanted = patch.filter { Self.fields.contains($0.key) }
        if !isOn, wanted["on"] == nil {
            guard !wanted.isEmpty else { return }
            deferred[deviceId, default: []].formUnion(wanted.keys)
            note("off: \(wanted.keys.sorted().joined(separator: ", ")) kept for the next switch-on")
            return
        }
        if wanted["on"] as? Bool == true, let kept = deferred.removeValue(forKey: deviceId) {
            for field in kept where wanted[field] == nil { wanted[field] = state[field] }
        }
        if wanted["on"] as? Bool == false { deferred[deviceId] = nil }

        let keys = TuyaMapper.infraredKeys(patch: wanted)
        var index = 0
        var replayed = false
        while index < keys.count {
            let key = keys[index]
            do {
                try await press(key, on: deviceId, send)
                index += 1
            } catch {
                let pending = keys[index...].map(\.field)
                if tuyaCode(of: error) == "2008", !replayed, isOn, key.field != "on" {
                    replayed = true
                    var rest = state.filter { Self.fields.contains($0.key) }
                    for field in pending + keys[..<index].map(\.field) { rest[field] = nil }
                    note("\(key.field) refused (2008): replaying \(rest.keys.sorted().joined(separator: ", "))")
                    for other in TuyaMapper.infraredKeys(patch: rest) { try? await press(other, on: deviceId, send) }
                    continue
                }
                let reason = tuyaCode(of: error) == "2008"
                    ? "this remote has no infrared code for that setting (Tuya code 2008)"
                    : error.localizedDescription
                throw Rejection(message: reason, fields: pending)
            }
        }
    }

    private func press(_ key: TuyaMapper.InfraredKey, on deviceId: String,
                       _ send: ([String: Any]) async throws -> Void) async throws {
        if let last = lastKey[deviceId] {
            let wait = spacing - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        defer { lastKey[deviceId] = Date() }
        try await send(key.command)
    }
}
