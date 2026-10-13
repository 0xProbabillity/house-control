import UIKit

/// The taps you feel while using the panel. The web UI names them; this plays them.
@MainActor
final class Haptics {
    static let shared = Haptics()

    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()
    private var lastTick = Date.distantPast

    func play(_ kind: String) {
        switch kind {
        case "tick":
            // A slider dragged quickly would otherwise buzz instead of tick.
            guard Date().timeIntervalSince(lastTick) > 0.045 else { return }
            lastTick = Date()
            selection.selectionChanged()
            selection.prepare()
        case "medium": medium.impactOccurred()
        case "heavy": heavy.impactOccurred()
        case "success": notification.notificationOccurred(.success)
        case "error": notification.notificationOccurred(.error)
        default: light.impactOccurred()
        }
    }
}
