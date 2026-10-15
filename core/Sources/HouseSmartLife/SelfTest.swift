import Foundation
import HouseCore

/// Offline self-checks and the read-only diagnostic behind the Mac binary's command line
/// flags (`--selftest-mapper`, `--selftest-infrared`, `--selftest-transport`, `--diagnose`).
public enum SelfTest {
    /// Runs the check named in `arguments` and exits; returns when none was asked for.
    @MainActor
    public static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        // Prints the Smart Life request envelope for fixed inputs, so the port can be
        // compared against the reference Python implementation.
        if arguments.contains("--selftest-transport") {
            typealias T = SmartLifeService.Transport
            let rid = "11111111-2222-3333-4444-555555555555"
            let hashKey = T.md5Hex(rid + "refresh-token")
            let secret = T.secret(requestId: rid, hashKey: hashKey)
            let enc = try! T.encrypt("{\"homeId\":\"42\"}", secret: secret, nonce: "ABCDEFGHJKMN")
            print(hashKey, secret, enc, try! T.decrypt(enc, secret: secret),
                  T.sign(hashKey: hashKey, headers: [("X-appKey", "app"), ("X-requestId", rid), ("X-sid", ""), ("X-time", "1700000000000"), ("X-token", "tok")], query: enc, body: ""),
                  separator: "\n")
            exit(0)
        }
        // Prints the commands built for typical actions.
        if arguments.contains("--selftest-mapper") {
            let ir: Set<String> = ["PowerOn", "PowerOff", "T", "M", "F"]
            let bulb: Set<String> = ["switch_led", "work_mode", "bright_value_v2", "temp_value_v2", "colour_data_v2"]
            let ranges: TuyaMapper.Ranges = ["bright_value_v2": (10, 1000), "temp_value_v2": (0, 1000)]
            let cases: [(String, [[String: Any]])] = [
                ("ir on+heat+24", TuyaMapper.acCommands(patch: ["on": true, "mode": "heat", "target": 24.0], link: [:], codes: ir)),
                ("ir off", TuyaMapper.acCommands(patch: ["on": false], link: [:], codes: ir)),
                ("ir fan high", TuyaMapper.acCommands(patch: ["fan": "high"], link: [:], codes: ir)),
                ("bulb on 50%", TuyaMapper.lightCommands(patch: ["on": true, "brightness": 0.5], state: [:], link: [:], codes: bulb, ranges: ranges)),
                ("bulb 2700K", TuyaMapper.lightCommands(patch: ["temp": 2700.0], state: [:], link: [:], codes: bulb, ranges: ranges)),
                ("bulb colour", TuyaMapper.lightCommands(patch: ["color": "#ff5a4f"], state: ["brightness": 0.8], link: [:], codes: bulb, ranges: ranges)),
                ("plug on (nothing known)", TuyaMapper.lightCommands(patch: ["on": true], state: [:], link: [:], codes: [])),
            ]
            for (name, commands) in cases {
                let data = try! JSONSerialization.data(withJSONObject: commands, options: [.sortedKeys])
                print(name, "→", String(data: data, encoding: .utf8)!)
            }
            exit(0)
        }
        // Plays typical changes against a simulated cloud remote whose temperature is fixed
        // in Auto mode, and prints the key presses.
        if arguments.contains("--selftest-infrared") {
            Task { @MainActor in
                for line in await infraredTranscript() { print(line) }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `--diagnose <id> [<id>…]` prints what Smart Life reports for those devices
        // (status + specification). It only reads; nothing is sent to the devices.
        if let flag = arguments.firstIndex(of: "--diagnose") {
            let ids = Array(arguments[(flag + 1)...])
            let directory = PlanStore().directory
            let cloud = SmartLifePlatform(directory: directory) { FileSecretStore(url: directory.appendingPathComponent("\($0).json")) }
            Task { @MainActor in
                let dump = await cloud.diagnostics(for: ids)
                let data = (try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                print(String(data: data, encoding: .utf8) ?? "{}")
                exit(0)
            }
            RunLoop.main.run()
        }
    }

    /// One line per case: the key presses an infrared AC received and how the change ended.
    @MainActor
    static func infraredTranscript() async -> [String] {
        let remote = InfraredRemote()
        remote.spacing = 0
        var cloud: [String: Any] = ["M": 2, "T": 24, "F": 0, "power": false] // what Tuya remembers
        var presses: [String] = []
        let send: ([String: Any]) async throws -> Void = { command in
            let code = command["code"] as? String ?? "", value = command["value"]
            if code == "T", cloud["M"] as? Int == 2 || value as? Int == 31 {
                presses.append("\(code)=\(value ?? "") ✗")
                throw SmartLifeService.Failure(message: "command or value not support (code 2008)", code: "2008")
            }
            presses.append("\(code)=\(value ?? "")")
            if code == "PowerOn" || code == "PowerOff" { cloud["power"] = code == "PowerOn" } else { cloud[code] = value }
        }
        let cases: [(String, [String: Any], [String: Any])] = [
            ("fan while off (kept)", ["fan": "high"], ["on": false, "mode": "cool", "target": 24.0, "fan": "high"]),
            ("switch on (sends the kept fan)", ["on": true], ["on": true, "mode": "cool", "target": 24.0, "fan": "high"]),
            ("25° while the cloud is in Auto", ["target": 25.0], ["on": true, "mode": "cool", "target": 25.0, "fan": "high"]),
            ("26° afterwards", ["target": 26.0], ["on": true, "mode": "cool", "target": 26.0, "fan": "high"]),
            ("a setting the remote lacks", ["target": 31.0], ["on": true, "mode": "cool", "target": 31.0, "fan": "high"]),
            ("switch off", ["on": false], ["on": false, "mode": "cool", "target": 26.0, "fan": "high"]),
        ]
        var lines: [String] = []
        for (name, patch, state) in cases {
            presses = []
            var outcome = "ok"
            do { try await remote.apply(patch: patch, state: state, to: "remote", send: send, note: { presses.append("(\($0))") }) }
            catch let rejected as InfraredRemote.Rejection { outcome = "rejected \(rejected.fields): \(rejected.message)" }
            catch { outcome = "\(error)" }
            lines.append("\(name) → \(presses.joined(separator: "  ")) → \(outcome)")
        }
        return lines
    }
}
