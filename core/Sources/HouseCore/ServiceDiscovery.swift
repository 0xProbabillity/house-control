import Foundation
import Network

/// A value that only ever changes on one serial queue.
private final class QueueBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Finds Home Assistant servers and Hue Bridges on the local network with Bonjour, so
/// connecting one is a click rather than typing an address.
public enum ServiceDiscovery {
    public struct Found {
        public var name: String
        public var host: String
        public var port: Int
        public var txt: [String: String]

        public var dictionary: [String: Any] { ["name": name, "host": host, "port": port, "txt": txt] }
    }

    /// Everything advertising `type` ("_hue._tcp", "_home-assistant._tcp") within `seconds`.
    public static func browse(_ type: String, seconds: Double = 3) async -> [Found] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
        let results: Set<NWBrowser.Result> = await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "house.discovery")
            let latest = QueueBox<Set<NWBrowser.Result>>([]) // touched on `queue` only
            browser.browseResultsChangedHandler = { results, _ in latest.value = results }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + seconds) {
                browser.cancel()
                continuation.resume(returning: latest.value)
            }
        }
        var out: [Found] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                for (key, value) in record.dictionary { txt[key] = value }
            }
            guard let (host, port) = await resolvePreferringIPv4(result.endpoint) else { continue }
            out.append(Found(name: name, host: host, port: port, txt: txt))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// The address behind a Bonjour service, IPv4 when it has one.
    ///
    /// A service usually answers on IPv6 too, and a resolution that takes whatever the system
    /// connects with first often yields a link-local address (`fe80::…`). Such an address only
    /// reaches devices on the same network segment: a Mac on another subnet of the same home
    /// (behind a mesh system or an extender in router mode) can never use it, and once its
    /// interface scope is dropped it is ambiguous on a Mac with several interfaces. IPv4 is
    /// tried first; IPv6 remains the fallback for IPv6-only networks.
    static func resolvePreferringIPv4(_ endpoint: NWEndpoint) async -> (String, Int)? {
        if let address = await resolve(endpoint, family: .v4) { return address }
        return await resolve(endpoint, family: nil)
    }

    /// The address behind a Bonjour service, found by opening (and closing) a connection to it
    /// over `family` (any family when nil).
    private static func resolve(_ endpoint: NWEndpoint, family: NWProtocolIP.Options.Version?) async -> (String, Int)? {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            if let family, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = family
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let queue = DispatchQueue(label: "house.discovery.resolve")
            let done = QueueBox(false) // touched on `queue` only
            let finish: @Sendable ((String, Int)?) -> Void = { value in
                guard !done.value else { return }
                done.value = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        finish((urlHost("\(host)"), Int(port.rawValue)))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    /// An address as the host part of a URL: IPv6 in brackets, without its interface scope
    /// ("fe80::1%en0" → "[fe80::1]"); IPv4 and names as they are.
    static func urlHost(_ address: String) -> String {
        var host = address
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        return host.contains(":") ? "[\(host)]" : host
    }

    /// Home Assistant servers: their advertised address when they have one.
    public static func homeAssistants() async -> [[String: Any]] {
        await browse("_home-assistant._tcp").map { found in
            let url = [found.txt["internal_url"], found.txt["base_url"]].compactMap { $0 }.first { !$0.isEmpty }
                ?? "http://\(found.host):\(found.port)"
            return ["name": found.txt["location_name"] ?? found.name, "url": url, "version": found.txt["version"] ?? ""]
        }
    }

    /// Hue Bridges: Bonjour first, then Philips' discovery service for networks that block it.
    public static func hueBridges() async -> [[String: Any]] {
        var out = await browse("_hue._tcp").map { found -> [String: Any] in
            // Real bridges serve HTTPS on 443; anything else (the lab's bridge) keeps its port.
            ["name": found.name, "host": found.port == 443 ? found.host : "\(found.host):\(found.port)",
             "bridgeId": found.txt["bridgeid"] ?? ""]
        }
        if out.isEmpty, let url = URL(string: "https://discovery.meethue.com/"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            out = list.compactMap { b in
                guard let ip = b["internalipaddress"] as? String else { return nil }
                return ["name": "Hue Bridge", "host": ip, "bridgeId": b["id"] as? String ?? ""]
            }
        }
        return out
    }
}
