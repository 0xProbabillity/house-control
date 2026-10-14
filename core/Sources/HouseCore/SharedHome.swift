import Foundation

/// The folder the app shares with its widgets (an App Group container): the home's
/// snapshot and the actions widgets made that the app still has to carry out.
///
/// The app writes `home.json` from what the panel shows; a widget applies its change to
/// that file at once (so it can redraw) and queues the action in `actions.json`. The app
/// takes the queue when it is told (a Darwin notification) or when it next comes up, and
/// runs each action through the panel, which sends it to the devices like a tap would.
/// Reads and writes of both files happen under one file lock, so the processes never see
/// half of the other's work.
public final class SharedHome: @unchecked Sendable {
    /// The Info.plist key that holds the App Group id of this build (it carries the
    /// signing team on the Mac, so it is set at build time).
    public static let groupKey = "HouseAppGroup"
    /// Posted by a widget after it queued an action, and by the app after it wrote a new snapshot.
    public static let actionsPosted = "io.github.0xprobabillity.HouseControl.widget-action"
    public static let snapshotWritten = "io.github.0xprobabillity.HouseControl.snapshot"

    public struct Queued: Codable, Equatable, Sendable {
        public var id: UUID
        public var action: HomeAction
        public var at: Double
        /// True when the widget reached the devices itself (the iPhone's Home Assistant, Hue,
        /// Smart Life): the app then only shows the result instead of sending it again.
        public var delivered: Bool
        /// The home it was made in ("custom", "home"…, plus its name): an app showing another
        /// home (a test run, another plan picked meanwhile) drops it.
        public var home: String?

        public init(_ action: HomeAction, home: String? = nil, delivered: Bool = false) {
            id = UUID()
            self.action = action
            at = Date().timeIntervalSince1970
            self.delivered = delivered
            self.home = home
        }
    }

    /// How long a queued action stays worth carrying out, in seconds.
    public static let patience: TimeInterval = 600

    public let directory: URL
    private var snapshotURL: URL { directory.appendingPathComponent("home.json") }
    private var queueURL: URL { directory.appendingPathComponent("actions.json") }
    private var lockURL: URL { directory.appendingPathComponent(".lock") }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The container of this build's App Group, or nil when the build has none (or the
    /// system refuses it, as it does for a Mac build signed without a team).
    public convenience init?(bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: Self.groupKey) as? String, !group.isEmpty,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        self.init(directory: url.appendingPathComponent("Widgets", isDirectory: true))
    }

    // MARK: - Snapshot

    public func snapshot() -> HomeSnapshot? {
        locked { readSnapshot() }
    }

    private func readSnapshot() -> HomeSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(HomeSnapshot.self, from: data)
    }

    private func writeSnapshot(_ snapshot: HomeSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    /// Stores what the app shows. Skipped while widget actions wait for the app: the
    /// snapshot already has their result, the app's view of the home does not yet.
    @discardableResult
    public func publish(_ snapshot: HomeSnapshot) -> Bool {
        locked {
            if !readQueue().isEmpty { return false }
            if var current = readSnapshot() {
                current.updated = snapshot.updated
                if current == snapshot { return false } // nothing a widget would draw differently
            }
            writeSnapshot(snapshot)
            return true
        }
    }

    // MARK: - Actions

    /// Applies `action` to the snapshot and queues it for the app. Returns the snapshot as
    /// it is now, the queued entry and what each device has to change; nil when there is no
    /// snapshot yet (the app has never run) or the action changes nothing.
    public func perform(_ action: HomeAction) -> (snapshot: HomeSnapshot, entry: Queued, changes: [DeviceChange])? {
        locked {
            guard var home = readSnapshot() else { return nil }
            let (resolved, changes) = home.apply(action)
            // A scene that is already on still counts: it is applied again (devices may differ).
            guard !changes.isEmpty || action.kind == .scene else { return nil }
            writeSnapshot(home)
            let entry = Queued(resolved, home: home.identity)
            var queue = readQueue()
            queue.append(entry)
            writeQueue(queue)
            return (home, entry, changes)
        }
    }

    /// Records that the widget reached the devices for these entries itself.
    public func markDelivered(_ ids: Set<UUID>) {
        locked {
            var queue = readQueue()
            for i in queue.indices where ids.contains(queue[i].id) { queue[i].delivered = true }
            writeQueue(queue)
        }
    }

    /// The queued actions, oldest first; the queue is empty afterwards.
    public func takeActions() -> (actions: [Queued], snapshot: HomeSnapshot?) {
        locked {
            let queue = readQueue()
            if !queue.isEmpty { writeQueue([]) }
            return (queue, readSnapshot())
        }
    }

    public var hasPendingActions: Bool { locked { !readQueue().isEmpty } }

    /// True once the app took `id` off the queue.
    public func isTaken(_ id: UUID) -> Bool { locked { !readQueue().contains { $0.id == id } } }

    private func readQueue() -> [Queued] {
        guard let data = try? Data(contentsOf: queueURL) else { return [] }
        // A tap the app could not carry out within a few minutes (it was not running) is
        // dropped: nobody expects a lamp to switch on an hour after they asked.
        let horizon = Date().timeIntervalSince1970 - Self.patience
        // One the widget delivered itself only tells the app what to show: it never goes stale.
        return ((try? JSONDecoder().decode([Queued].self, from: data)) ?? []).filter { $0.delivered || $0.at > horizon }
    }

    private func writeQueue(_ queue: [Queued]) {
        if queue.isEmpty { try? FileManager.default.removeItem(at: queueURL); return }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    // MARK: - Locking

    private func locked<T>(_ body: () -> T) -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    // MARK: - Darwin notifications (they cross process boundaries, carry no data)

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    @MainActor private static var observers: [String: () -> Void] = [:]

    /// Calls `handler` on the main queue whenever `name` is posted, by any process.
    @MainActor
    public static func observe(_ name: String, _ handler: @escaping () -> Void) {
        observers[name] = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
            guard let key = name?.rawValue as String? else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { SharedHome.observers[key]?() } }
        }, name as CFString, nil, .deliverImmediately)
    }
}
