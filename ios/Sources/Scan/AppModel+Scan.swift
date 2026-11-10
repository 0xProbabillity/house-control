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
        if let name, !name.isEmpty { scanName = name } else { scanName = customPlanName ?? "My home" }
        let covered = showSettings || showNewHome || showWelcome
        showSettings = false
        showNewHome = false
        showWelcome = false
        Task { @MainActor in
            if covered { try? await Task.sleep(nanoseconds: 450_000_000) }
            showScan = true
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
            show(Banner(symbol: "exclamationmark.triangle.fill", text: "Could not save the scanned home", tint: Theme.red))
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
                show(Banner(symbol: "cube.transparent.fill", text: floor.map { "\($0) added to \(customPlanName ?? "your home")" }
                            ?? "\(customPlanName ?? "Your home") is ready", tint: Theme.green))
            }
        }
    }
}
#endif
