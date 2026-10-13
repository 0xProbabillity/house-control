import Foundation

/// Persists which floor plan is active and the user's own plan file.
/// Everything lives in ~/Library/Application Support/HouseControl (or HOUSE_DATA_DIR).
final class PlanStore {
    static let bundled = ["home", "studio"]

    let directory: URL
    var customPlanURL: URL { directory.appendingPathComponent("plan.json") }
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    /// "home" / "studio" for the bundled demos, or "custom" for plan.json.
    private(set) var activePlan = "home"

    init() {
        // HOUSE_DATA_DIR points the app at another folder: a throw-away one for testing or
        // screenshots leaves the real plan and the Smart Life session alone.
        if let custom = ProcessInfo.processInfo.environment["HOUSE_DATA_DIR"], !custom.isEmpty {
            directory = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appendingPathComponent("HouseControl", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let plan = json["plan"] as? String {
            activePlan = plan
        }
        if activePlan == "custom", customPlan() == nil { activePlan = "home" }
    }

    func customPlan() -> [String: Any]? {
        guard let data = try? Data(contentsOf: customPlanURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    var hasCustomPlan: Bool { FileManager.default.fileExists(atPath: customPlanURL.path) }

    func select(_ plan: String) {
        guard Self.bundled.contains(plan) || (plan == "custom" && customPlan() != nil) else { return }
        activePlan = plan
        let data = try? JSONSerialization.data(withJSONObject: ["plan": plan])
        try? data?.write(to: settingsURL, options: .atomic)
    }

    /// Stores `plan` as the user's plan and makes it active.
    func saveCustom(_ plan: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: customPlanURL, options: .atomic)
        select("custom")
    }

    func importPlan(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let plan = try JSONSerialization.jsonObject(with: data) as? [String: Any], plan["rooms"] is [Any] else {
            throw NSError(domain: "HouseControl", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This file is not a House Control floor plan (no \"rooms\" list)."])
        }
        try saveCustom(plan)
    }

    /// The plan the UI should render: the custom JSON inline, or the name of a bundled demo.
    func bootPayload() -> [String: Any] {
        var boot: [String: Any] = ["plan": activePlan, "hasCustomPlan": hasCustomPlan]
        if activePlan == "custom", let plan = customPlan() { boot["config"] = plan }
        return boot
    }
}
