import Foundation

/// A small text log of what was sent to real devices and what the cloud answered:
/// `events.log` next to the plan. It is the first thing to look at when a device
/// does not react. Never contains tokens; it stays on this Mac.
public final class EventLog {
    private let url: URL
    private static let limit = 256 * 1024
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    public init(directory: URL) { url = directory.appendingPathComponent("events.log") }

    public var fileURL: URL { url }

    public func write(_ line: String) {
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        // Keep the newer half once the file has grown past the limit.
        if let size = try? handle.seekToEnd(), size > Self.limit, let old = try? Data(contentsOf: url) {
            let tail = old.suffix(Self.limit / 2)
            let cut = tail.firstIndex(of: 0x0A).map { tail.suffix(from: tail.index(after: $0)) } ?? tail
            try? (cut + data).write(to: url, options: .atomic)
            return
        }
        try? handle.write(contentsOf: data)
    }

    public static func describe(_ commands: [[String: Any]]) -> String {
        commands.map { "\($0["code"] ?? "?")=\($0["value"] ?? "?")" }.joined(separator: " ")
    }
}
