import Foundation
import ServiceManagement

/// "Open at Login": the app registers itself as a login item, the one listed in
/// System Settings → General → Login Items, where it can be switched off as well.
@MainActor
enum LoginItem {
    enum State: String { case on, off, needsApproval }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    /// Run from the disk image, or from the temporary place macOS runs a downloaded app from until it has
    /// been moved (App Translocation): a login item would point at a copy that is gone after a restart.
    static var isTemporaryCopy: Bool {
        let url = Bundle.main.bundleURL
        if url.path.contains("/AppTranslocation/") { return true }
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    /// In /Applications or ~/Applications, where a copy is meant to stay.
    private static var isInstalled: Bool {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent().path
        return folder == "/Applications" || folder == NSHomeDirectory() + "/Applications"
    }

    /// Where the app was when it registered.
    private static let registeredPathKey = "loginItemPath"

    /// Switches it on or off. When macOS wants the user to allow it first, opens Login Items for them.
    static func set(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return
            }
            // Registering again points the login item at this copy of the app.
            if service.status == .enabled { try? service.unregister() }
            try service.register()
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: registeredPathKey)
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    /// At launch: when the app has been moved into Applications since it registered, the login item
    /// follows it. Copies run from anywhere else (a build folder, say) leave it alone.
    static func followMove() {
        guard state == .on, isInstalled,
              UserDefaults.standard.string(forKey: registeredPathKey) != Bundle.main.bundlePath else { return }
        try? set(true)
    }
}
