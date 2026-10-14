import Foundation
import WidgetKit

/// The app's side of the widgets: keeps the shared snapshot up to date with what the
/// panel shows, and hands the panel what widgets and controls did while it was not looking.
@MainActor
public final class WidgetBridge {
    public let shared: SharedHome?
    /// Runs actions widgets queued (the panel sends them to the devices) and, when some
    /// were already delivered by a widget itself, the state to show for them.
    public var onActions: ((_ run: [[String: Any]], _ adopt: [String: Any]?) -> Void)?
    /// False until the panel page has started; actions wait for it.
    public var isReady = false {
        didSet { if isReady { takeActions() } else { identity = nil } }
    }
    /// Told about every snapshot the panel posts (the iPhone's quick actions are built from it).
    public var onSnapshot: ((HomeSnapshot) -> Void)?
    /// The home the panel shows, from its last snapshot.
    private var identity: String?
    private var reload: DispatchWorkItem?
    private var lastReload = Date.distantPast

    public init(shared: SharedHome? = SharedHome()) {
        self.shared = shared
        guard shared != nil else { return }
        SharedHome.observe(SharedHome.actionsPosted) { [weak self] in self?.takeActions() }
    }

    /// The panel's `widgets` message.
    public func publish(_ message: [String: Any]) {
        guard let object = message["snapshot"],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let snapshot = try? JSONDecoder().decode(HomeSnapshot.self, from: data) else { return }
        onSnapshot?(snapshot)
        let first = identity == nil
        identity = snapshot.identity
        // The queue waited to learn which home this is. When it held something, this
        // snapshot is already out of date: the panel posts a new one once it has caught up.
        if first, takeActions() { return }
        if shared?.publish(snapshot) == true { scheduleReload() }
    }

    /// Takes the queue (when the app comes to the foreground, or a widget says it added to it).
    /// True when there was something for the panel.
    @discardableResult
    public func takeActions() -> Bool {
        guard isReady, identity != nil, let shared, shared.hasPendingActions else { return false }
        let (all, snapshot) = shared.takeActions()
        // Made for another home than the one on screen: never carry those out here.
        let queued = all.filter { $0.home == identity }
        guard !queued.isEmpty else { scheduleReload(); return false }
        let encoder = JSONEncoder()
        let run = queued.filter { !$0.delivered }.compactMap { entry -> [String: Any]? in
            guard let data = try? encoder.encode(entry.action) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let adopt = queued.contains(where: \.delivered) ? snapshot?.panelState : nil
        onActions?(run, adopt)
        return true
    }

    /// Widgets redraw at most a couple of times a second, however fast the panel changes.
    private func scheduleReload() {
        reload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
            if #available(iOS 18.0, macOS 26.0, *) { ControlCenter.shared.reloadAllControls() }
        }
        reload = work
        let wait = max(0.15, 0.6 - Date().timeIntervalSince(lastReload))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }
}
