#if ROOM_SCAN
import SwiftUI
import HouseCore

extension AppModel {
    /// True on an iPhone that has a LiDAR camera.
    var canScan: Bool { ScanController.isSupported }

    /// Where the last scan is kept as RoomPlan measured it, beside the plan.
    var scanSaveURL: URL { plans.directory.appendingPathComponent("last-scan.json") }

    /// Opens the scanner for a home called `name`, once any sheet in the way has gone.
    func openScan(name: String? = nil) {
        scanReplay = nil
        if let name, !name.isEmpty { scanName = name } else { scanName = customPlanName ?? String(localized: "My home", comment: "Name of the user's own home while it has none") }
        let covered = showSettings || showNewHome || showWelcome
        showSettings = false
        showNewHome = false
        showWelcome = false
        Task { @MainActor in
            if covered { try? await Task.sleep(nanoseconds: 450_000_000) }
            showScan = true
        }
    }

    /// What the banner says once a scan is saved: a floor added, or the home ready.
    private func scannedBanner(floor: String?) -> String {
        switch (floor, customPlanName) {
        case let (floor?, home?): String(localized: "\(floor) added to \(home)", comment: "Banner after a scan: a floor added to the home; the placeholders are the floor's and the home's names")
        case let (floor?, nil): String(localized: "\(floor) added to your home", comment: "Banner after a scan; the placeholder is the floor's name")
        case let (nil, home?): String(localized: "\(home) is ready", comment: "Banner after a scan; the placeholder is the home's name")
        case (nil, nil): String(localized: "Your home is ready", comment: "Banner after a scan")
        }
    }

    /// Saves a scanned home as this phone's home, or as a new floor of the home already here.
    func saveScan(_ scanned: [String: Any], asFloor floor: String?, edit: Bool) {
        var plan = scanned
        if let floor, let home = plans.customPlan() {
            plan = ScanLayout.adding(scanned, asFloor: floor, to: home)
        }
        do {
            try savePlan(plan)
        } catch {
            show(Banner(symbol: "exclamationmark.triangle.fill", text: String(localized: "Could not save the scanned home", comment: "Banner"), tint: Theme.red))
            return
        }
        UserDefaults.standard.set(true, forKey: "welcomed")
        Haptics.shared.play("success")
        showScan = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if edit {
                openEditor()
            } else {
                show(Banner(symbol: "cube.transparent.fill", text: scannedBanner(floor: floor), tint: Theme.green))
            }
        }
    }
}
#endif
