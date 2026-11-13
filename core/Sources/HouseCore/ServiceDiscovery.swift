import Foundation
import Network
import dnssd

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
            guard let (host, port) = await resolve(result.endpoint) else { continue }
            out.append(Found(name: name, host: host, port: port, txt: txt))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Prefer the advertised hostname so saved connections survive interface changes.
    private static func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
        if case .service(let name, let type, let domain, let interface) = endpoint,
           let resolved = await BonjourServiceResolver().resolve(
               name: name, type: type, domain: domain, interfaceIndex: UInt32(interface?.index ?? 0)
           ) {
            return resolved
        }
        guard !Task.isCancelled else { return nil }
        return await resolveAddress(endpoint)
    }

    /// Fall back to the address selected by Network.framework when SRV resolution fails.
    private static func resolveAddress(_ endpoint: NWEndpoint) async -> (String, Int)? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let queue = DispatchQueue(label: "house.discovery.resolve")
                let done = QueueBox(false) // touched on `queue` only
                let finish: @Sendable ((String, Int)?) -> Void = { value in
                    guard !done.value else { return }
                    done.value = true
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: value)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                            var name = "\(host)"
                            if name.contains(":") {
                                // Link-local IPv6 needs its interface scope (for example, %en11)
                                // to be routable. RFC 6874 encodes the percent sign in a URL host.
                                name = "[\(name.replacingOccurrences(of: "%", with: "%25"))]"
                            }
                            finish((name, Int(port.rawValue)))
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
        } onCancel: {
            connection.cancel()
        }
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

/// Resolves the Bonjour SRV record without pinning the result to the interface used for discovery.
final class BonjourServiceResolver: @unchecked Sendable {
    // DNS-SD callbacks, cancellation and deallocation all run on this queue.
    private let queue = DispatchQueue(label: "house.discovery.srv")
    private var service: DNSServiceRef?
    private var continuation: CheckedContinuation<(String, Int)?, Never>?
    private var cancelled = false

    func resolve(name: String, type: String, domain: String, interfaceIndex: UInt32) async -> (String, Int)? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    guard !self.cancelled else { self.finish(nil); return }
                    var sdRef: DNSServiceRef?
                    let context = Unmanaged.passUnretained(self).toOpaque()
                    let error = DNSServiceResolve(&sdRef, 0, interfaceIndex, name, type, domain,
                                                  Self.didResolve, context)
                    self.service = sdRef
                    guard error == kDNSServiceErr_NoError, let sdRef,
                          DNSServiceSetDispatchQueue(sdRef, self.queue) == kDNSServiceErr_NoError else {
                        self.finish(nil)
                        return
                    }
                    // Keep the C callback context alive even after the async method suspends.
                    self.queue.asyncAfter(deadline: .now() + 3) { self.finish(nil) }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(nil)
            }
        }
    }

    private static let didResolve: DNSServiceResolveReply = { _, _, _, error, _, target, port, _, _, context in
        guard let context else { return }
        let resolver = Unmanaged<BonjourServiceResolver>.fromOpaque(context).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError, let target else {
            resolver.finish(nil)
            return
        }
        let hostname = String(cString: target).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        resolver.finish(hostname.isEmpty ? nil : (hostname, Int(UInt16(bigEndian: port))))
    }

    private func finish(_ result: (String, Int)?) {
        guard let continuation else { return }
        self.continuation = nil
        if let service { DNSServiceRefDeallocate(service) }
        self.service = nil
        continuation.resume(returning: result)
    }
}
