import Foundation
import UserNotifications

/// The AC auto-off timers, as far as the iPhone can keep them.
///
/// The panel runs the timers (web/src/store.js), and it only runs while the app is in front:
/// iOS gives an app in the background no way to switch something off at a set time. So for
/// each running timer a notification is scheduled for the moment it runs out. Its
/// **Switch Off** button switches the AC off from the background, without opening the app;
/// tapping the notification opens the app, whose panel then switches it off at once. While
/// the app is in front the panel does it itself and the notification stays quiet.
@MainActor
final class ACTimerReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ACTimerReminders()

    private static let prefix = "actimer."
    private static let category = "acTimer"
    private static let switchOff = "switchOff"

    /// Switches an AC off from a notification: (device id, its state with `on` false).
    var onSwitchOff: ((String, [String: Any]) async -> Void)?
    private var asked = false

    /// Called as the app starts, before any notification can be answered.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.switchOff,
                                          title: String(localized: "Switch Off", comment: "Notification button: switches the air conditioner off now"),
                                          options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [action],
                                                                 intentIdentifiers: [], options: [])])
    }

    /// The panel's running timers: `[{id, name, end (ms since 1970), state}]`.
    func update(_ timers: [[String: Any]]) {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let wanted = timers.compactMap { timer -> UNNotificationRequest? in
            guard let id = timer["id"] as? String, let end = (timer["end"] as? NSNumber)?.doubleValue else { return nil }
            let at = Date(timeIntervalSince1970: end / 1000)
            guard at.timeIntervalSince(now) > 1 else { return nil }
            let content = UNMutableNotificationContent()
            content.title = timer["name"] as? String ?? String(localized: "Air conditioner", comment: "Notification title when the AC has no name")
            content.body = String(localized: "The timer is up. Tap to switch it off, or touch and hold for Switch Off.",
                                  comment: "Notification when an air conditioner's auto-off timer runs out while the app is closed")
            content.sound = .default
            content.categoryIdentifier = Self.category
            content.threadIdentifier = Self.category
            content.userInfo = ["id": id, "state": Self.plist(timer["state"] as? [String: Any] ?? [:])]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSince(now), repeats: false)
            return UNNotificationRequest(identifier: Self.prefix + id, content: content, trigger: trigger)
        }
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            Task { @MainActor in
                center.removePendingNotificationRequests(withIdentifiers: stale)
                guard !wanted.isEmpty else { return }
                await self.askOnce()
                for request in wanted { try? await center.add(request) }
            }
        }
    }

    /// The first timer asks whether the app may notify; later ones go by that answer.
    private func askOnce() async {
        guard !asked else { return }
        asked = true
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Only what a notification's userInfo can hold (no nulls).
    private static func plist(_ state: [String: Any]) -> [String: Any] {
        state.filter { !($0.value is NSNull) && ($0.value is String || $0.value is NSNumber) }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// In front, the panel switches the AC off itself and says so.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let ours = notification.request.identifier.hasPrefix(Self.prefix)
        completionHandler(ours ? [] : [.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard action == Self.switchOff, let id = info["id"] as? String else {
            completionHandler() // opening the app is enough: the panel switches it off
            return
        }
        let state = info["state"] as? [String: Any] ?? [:]
        Task { @MainActor in
            // A launch into the background may come before the app has set itself up.
            for _ in 0..<40 where onSwitchOff == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            await onSwitchOff?(id, state)
            completionHandler()
        }
    }
}
