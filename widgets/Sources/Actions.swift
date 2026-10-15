import Foundation
import WidgetKit
import HouseCore
#if SMART_LIFE
import HouseSmartLife
#endif

/// Carries out what a widget or a control asked for.
///
/// The change is applied to the shared snapshot first (so every widget can redraw with it
/// at once) and queued for the app. On the Mac the app is running in the menu bar: it takes
/// the queue straight away and sends the change through the panel, like a click there.
/// On the iPhone the app is usually not running, so the widget reaches Home Assistant, Hue
/// and Smart Life (where it is built in) itself, with the connections the app keeps in the
/// shared Keychain group; what it cannot reach from here (Apple Home) waits for the app to open.
enum WidgetActions {
    /// Returns false when the action could not be applied (no home yet, or nothing changed).
    @discardableResult
    static func run(_ action: HomeAction) async -> Bool {
        guard let shared = SharedHome(), let done = shared.perform(action) else { return false }
        SharedHome.post(SharedHome.actionsPosted)
        #if os(iOS)
        if await deliver(done.changes, home: done.snapshot, shared: shared) {
            shared.markDelivered([done.entry.id])
        }
        #else
        // The app takes the action within a few milliseconds when it runs; its panel then
        // posts the new state. Waiting for that lets the widget redraw with the real result.
        for _ in 0..<25 where !shared.isTaken(done.entry.id) {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        if shared.isTaken(done.entry.id) { try? await Task.sleep(nanoseconds: 450_000_000) }
        #endif
        reloadEverything()
        return true
    }

    static func reloadEverything() {
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, macOS 26.0, *) { ControlCenter.shared.reloadAllControls() }
    }

    #if os(iOS)
    /// The platforms a widget can reach without the app.
    #if SMART_LIFE
    private static let reachable: Set<String> = ["smartlife", "homeassistant", "hue"]
    #else
    private static let reachable: Set<String> = ["homeassistant", "hue"]
    #endif

    /// True when every change reached its device (simulated devices always do).
    @MainActor
    private static func deliver(_ changes: [DeviceChange], home: HomeSnapshot, shared: SharedHome) async -> Bool {
        let services = Dictionary(uniqueKeysWithValues: home.lights.map { ($0.id, $0.service) } + home.acs.map { ($0.id, $0.service) })
        let real = changes.filter { services[$0.id] ?? nil != nil }
        guard !real.isEmpty else { return true }
        if real.contains(where: { !reachable.contains((services[$0.id] ?? nil) ?? "") }) { return false }
        let app = appBundleIdentifier
        let directory = shared.directory.appendingPathComponent("Hub", isDirectory: true)
        let secret: (String) -> SecretStore = { KeychainSecretStore(service: app, account: $0) }
        #if SMART_LIFE
        let hub = DeviceHub(directory: directory, secret: secret, cloud: SmartLifePlatform.init)
        #else
        let hub = DeviceHub(directory: directory, secret: secret)
        #endif
        hub.setLinks(from: home.linksPlan)
        var ok = true
        for change in real {
            let reply: [String: Any] = await withCheckedContinuation { done in
                hub.command(change.message) { done.resume(returning: $0) }
            }
            if reply["error"] != nil { ok = false }
        }
        return ok
    }

    /// The app's bundle id ("….HouseControl"): its Keychain items are filed under it.
    private static var appBundleIdentifier: String {
        let own = Bundle.main.bundleIdentifier ?? ""
        return own.components(separatedBy: ".").dropLast().joined(separator: ".")
    }
    #endif
}
