import Foundation
import Security

/// Gives the loopback AI gateway a public HTTPS address through a Cloudflare Quick Tunnel:
/// `cloudflared tunnel --url http://127.0.0.1:<port>`. No Cloudflare account, nothing to
/// configure; every start gets a new random `*.trycloudflare.com` name, and stopping the
/// process makes that name disappear for good.
///
/// cloudflared is found in Homebrew's usual places, or downloaded on request from
/// Cloudflare's own GitHub releases into the app's data folder.
@MainActor
final class CloudflareTunnel {
    enum State: Equatable {
        case stopped
        case starting
        case live(URL)
        case failed(String)
    }

    private(set) var state: State = .stopped { didSet { if state != oldValue { onChange?(state) } } }
    var onChange: ((State) -> Void)?

    private var process: Process?
    private var output = ""
    private var publicURL: URL?
    private var readyCheck: DispatchWorkItem?
    private let directory: URL
    private var pidFile: URL { directory.appendingPathComponent("cloudflared.pid") }
    /// Where a downloaded copy is kept.
    var bundledBinary: URL { directory.appendingPathComponent("bin/cloudflared") }

    init(directory: URL) {
        self.directory = directory
        killLeftover()
    }

    /// The cloudflared to run, if there is one.
    var binary: URL? {
        let candidates = [bundledBinary.path, "/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/cloudflared" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    func start(port: UInt16) {
        stop()
        guard let binary else { state = .failed("Cloudflare's connector (cloudflared) is not installed."); return }
        let process = Process()
        process.executableURL = binary
        // cloudflared reads ~/.cloudflared/config.yml when it exists; a quick tunnel must not
        // pick up the user's own named-tunnel settings, so it gets an empty file of its own.
        let config = directory.appendingPathComponent("cloudflared.yml")
        if !FileManager.default.fileExists(atPath: config.path) { try? Data("# House Control quick tunnel\n".utf8).write(to: config) }
        process.arguments = ["tunnel", "--no-autoupdate", "--config", config.path, "--metrics", "127.0.0.1:0",
                             "--url", "http://127.0.0.1:\(port)"]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.consume(text) }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                try? FileManager.default.removeItem(at: self.pidFile)
                let tail = self.output.split(separator: "\n").suffix(3).joined(separator: " ")
                self.state = .failed(Self.explain(tail))
            }
        }
        output = ""
        publicURL = nil
        state = .starting
        do {
            try process.run()
            self.process = process
            try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            state = .failed("Could not start cloudflared: \(error.localizedDescription)")
        }
    }

    func stop() {
        readyCheck?.cancel()
        readyCheck = nil
        if let process {
            self.process = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            process.terminate()
        }
        try? FileManager.default.removeItem(at: pidFile)
        publicURL = nil
        state = .stopped
    }

    private func consume(_ text: String) {
        guard process != nil else { return }
        output += text
        if output.count > 20_000 { output = String(output.suffix(10_000)) }
        if publicURL == nil, let range = output.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) {
            publicURL = URL(string: String(output[range]))
        }
        // The address is printed before the edge accepts it; it works once a connection is registered.
        if let url = publicURL, case .starting = state, output.contains("Registered tunnel connection") {
            let check = DispatchWorkItem { [weak self] in
                guard let self, self.process != nil, case .starting = self.state else { return }
                self.state = .live(url)
            }
            readyCheck = check
            // A moment for the new name to reach Cloudflare's DNS everywhere.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: check)
        }
        if case .starting = state, output.contains("failed to request quick Tunnel") || output.contains("429 Too Many Requests") {
            let tail = output.split(separator: "\n").suffix(2).joined(separator: " ")
            stop()
            state = .failed(Self.explain(tail))
        }
    }

    private static func explain(_ log: String) -> String {
        if log.contains("429") { return "Cloudflare is limiting new quick tunnels right now. Try again in a minute." }
        if log.contains("no such host") || log.contains("dial tcp") || log.contains("network is unreachable") {
            return "Cloudflare could not be reached. Check the internet connection."
        }
        return log.isEmpty ? "The tunnel stopped." : "The tunnel stopped: \(log.prefix(160))"
    }

    /// A cloudflared left running by a previous run of the app (after a crash) would keep an
    /// address alive that leads nowhere; it is stopped at launch.
    private func killLeftover() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer).hasSuffix("cloudflared") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    // MARK: - Download

    private(set) var isDownloading = false

    /// Fetches the latest cloudflared for this Mac from Cloudflare's GitHub releases and
    /// keeps it only if it carries Cloudflare's Developer ID signature.
    func download() async throws {
        isDownloading = true
        defer { isDownloading = false }
        #if arch(arm64)
        let asset = "cloudflared-darwin-arm64.tgz"
        #else
        let asset = "cloudflared-darwin-amd64.tgz"
        #endif
        let url = URL(string: "https://github.com/cloudflare/cloudflared/releases/latest/download/\(asset)")!
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TunnelError("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0).") }
        let work = directory.appendingPathComponent("bin/unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", file.path, "-C", work.path]
        try tar.run()
        tar.waitUntilExit()
        let unpacked = work.appendingPathComponent("cloudflared")
        guard tar.terminationStatus == 0, FileManager.default.fileExists(atPath: unpacked.path) else { throw TunnelError("The download could not be unpacked.") }
        guard Self.signedByCloudflare(unpacked) else { throw TunnelError("The downloaded file is not signed by Cloudflare, so it was not kept.") }
        try? FileManager.default.removeItem(at: bundledBinary)
        try FileManager.default.moveItem(at: unpacked, to: bundledBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledBinary.path)
    }

    /// A valid Developer ID signature whose certificate names Cloudflare.
    static func signedByCloudflare(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first, let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return false }
        return summary.localizedCaseInsensitiveContains("Cloudflare")
    }

    struct TunnelError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
