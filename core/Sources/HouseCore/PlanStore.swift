import Foundation
import CryptoKit

/// Persists which floor plan is active and the user's own plan file.
/// Everything lives in ~/Library/Application Support/HouseControl (or HOUSE_DATA_DIR).
public final class PlanStore {
    public static let bundled = ["home", "studio"]

    public let directory: URL
    public var customPlanURL: URL { directory.appendingPathComponent("plan.json") }
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    /// "home" / "studio" for the bundled demos, or "custom" for plan.json.
    public private(set) var activePlan = "home"

    public init() {
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

    public func customPlan() -> [String: Any]? {
        guard let data = try? Data(contentsOf: customPlanURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public var hasCustomPlan: Bool { FileManager.default.fileExists(atPath: customPlanURL.path) }

    /// The name the user gave their home, for menus.
    public var customPlanName: String? { customPlan()?["name"] as? String }

    /// Fingerprint of the user's plan as stored; two devices holding the same revision
    /// have nothing to exchange.
    public var customPlanRevision: String? {
        (try? Data(contentsOf: customPlanURL)).map(Self.revision(of:))
    }

    public static func revision(of data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func select(_ plan: String) {
        guard Self.bundled.contains(plan) || (plan == "custom" && customPlan() != nil) else { return }
        activePlan = plan
        let data = try? JSONSerialization.data(withJSONObject: ["plan": plan])
        try? data?.write(to: settingsURL, options: .atomic)
    }

    /// Stores `plan` as the user's plan and makes it active.
    public func saveCustom(_ plan: [String: Any]) throws {
        try saveCustom(data: Self.encode(plan))
    }

    /// Stores an already serialised plan byte for byte, so its revision matches the sender's.
    public func saveCustom(data: Data, select: Bool = true) throws {
        try data.write(to: customPlanURL, options: .atomic)
        if select { self.select("custom") }
    }

    public static func encode(_ plan: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Checks that `data` is a floor plan at all before it replaces the user's one.
    public static func validate(_ data: Data) throws -> [String: Any] {
        guard let plan = try JSONSerialization.jsonObject(with: data) as? [String: Any], plan["rooms"] is [Any] else {
            throw NSError(domain: "HouseControl", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This file is not a House Control floor plan (no \"rooms\" list)."])
        }
        return plan
    }

    public func importPlan(from url: URL) throws {
        try saveCustom(Self.validate(try Data(contentsOf: url)))
    }

    /// Forgets the user's plan and falls back to the bundled demo.
    public func removeCustom() {
        try? FileManager.default.removeItem(at: customPlanURL)
        if activePlan == "custom" { select("home") }
    }

    /// The plan the UI should render: the custom JSON inline, or the name of a bundled demo.
    public func bootPayload() -> [String: Any] {
        var boot: [String: Any] = ["plan": activePlan, "hasCustomPlan": hasCustomPlan]
        if activePlan == "custom", let plan = customPlan() { boot["config"] = plan }
        return boot
    }
}
