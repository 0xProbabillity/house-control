import Foundation
import Network

/// One HTTP request, as much of it as the AI gateway needs.
public struct HTTPRequest {
    public var method: String
    /// The path without the query, percent-decoded segment by segment by the router.
    public var path: String
    public var query: [String: String]
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(_ text: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: Data(text.utf8))
    }

    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    public static let notFound = HTTPResponse.text("Not found\n", status: 404)

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 503: return "Service Unavailable"
        default: return status < 400 ? "OK" : "Error"
        }
    }
}

/// A deliberately small HTTP/1.1 server for the AI gateway. It listens on the loopback
/// interface only: the outside world reaches it through the tunnel process (which runs
/// on this Mac and connects to 127.0.0.1), never directly, and nothing on the local
/// network can see it.
@MainActor
public final class LoopbackHTTPServer {
    public typealias Handler = @MainActor (HTTPRequest) async -> HTTPResponse

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let handler: Handler
    /// Requests larger than this are refused (a floor plan is a few dozen kB).
    public var maxBody = 4 * 1024 * 1024

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var port: UInt16? { listener?.port?.rawValue }
    public var isRunning: Bool { listener != nil }

    /// Starts listening on 127.0.0.1, on `preferredPort` if it is free and on any port
    /// otherwise. Calls back with the port once the listener is ready.
    public func start(preferredPort: UInt16 = 0, ready: @escaping @MainActor (Result<UInt16, Error>) -> Void) {
        stop()
        do {
            let listener = try makeListener(port: preferredPort)
            install(listener, preferredPort: preferredPort, ready: ready)
        } catch {
            if preferredPort != 0 { start(preferredPort: 0, ready: ready) } else { ready(.failure(error)) }
        }
    }

    private func makeListener(port: UInt16) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        return try NWListener(using: parameters)
    }

    private func install(_ listener: NWListener, preferredPort: UInt16, ready: @escaping @MainActor (Result<UInt16, Error>) -> Void) {
        var reported = false
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    if !reported, let port = listener.port?.rawValue { reported = true; ready(.success(port)) }
                case .failed(let error):
                    self.stop()
                    if !reported {
                        reported = true
                        // The preferred port is taken: any free one will do.
                        if preferredPort != 0 { self.start(preferredPort: 0, ready: ready) } else { ready(.failure(error)) }
                    }
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.connections[key] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    /// Serves requests one after another on a kept-alive connection: answers whatever is
    /// already buffered, and reads more when a request is still incomplete.
    private func read(_ connection: NWConnection, buffer: Data) {
        var buffer = buffer
        switch HTTPParser.parse(&buffer, maxBody: maxBody) {
        case .invalid(let status):
            send(.text("Bad request\n", status: status), close: true, on: connection, rest: Data())
        case .request(let request, let keepAlive):
            Task { @MainActor in
                let response = await self.handler(request)
                self.send(response, close: !keepAlive, on: connection, rest: buffer)
            }
        case .incomplete:
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, _, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let data, !data.isEmpty, error == nil else { connection.cancel(); return }
                    self.read(connection, buffer: buffer + data)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, close: Bool, on connection: NWConnection, rest: Data) {
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = headers["Content-Length"] ?? String(response.body.count)
        headers["Connection"] = close ? "close" : "keep-alive"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"
        headers["X-Robots-Tag"] = "noindex, nofollow"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                if close { connection.cancel() } else { self?.read(connection, buffer: rest) }
            }
        })
    }
}

/// Parses HTTP/1.1 requests out of a byte buffer (fixed length and chunked bodies).
enum HTTPParser {
    enum Result {
        case incomplete
        case invalid(Int)
        case request(HTTPRequest, keepAlive: Bool)
    }

    /// On success the request's bytes are removed from `buffer`.
    static func parse(_ buffer: inout Data, maxBody: Int) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > 64 * 1024 ? .invalid(400) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(400) }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var cursor = end.upperBound
        var body = Data()
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                guard let lineEnd = buffer[cursor...].range(of: Data("\r\n".utf8)) else { return .incomplete }
                let sizeText = String(data: buffer[cursor..<lineEnd.lowerBound], encoding: .ascii)?
                    .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let size = Int(sizeText, radix: 16) else { return .invalid(400) }
                cursor = lineEnd.upperBound
                if size == 0 {
                    // Trailers, if any, end with an empty line.
                    guard let trailerEnd = buffer[cursor...].range(of: Data("\r\n".utf8)) else { return .incomplete }
                    if trailerEnd.lowerBound != cursor {
                        guard let rest = buffer[cursor...].range(of: separator) else { return .incomplete }
                        cursor = rest.upperBound
                    } else {
                        cursor = trailerEnd.upperBound
                    }
                    break
                }
                guard body.count + size <= maxBody else { return .invalid(413) }
                guard buffer.distance(from: cursor, to: buffer.endIndex) >= size + 2 else { return .incomplete }
                body.append(buffer[cursor..<buffer.index(cursor, offsetBy: size)])
                cursor = buffer.index(cursor, offsetBy: size + 2)
            }
        } else if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else { return .invalid(400) }
            guard length <= maxBody else { return .invalid(413) }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= length else { return .incomplete }
            body = Data(buffer[cursor..<buffer.index(cursor, offsetBy: length)])
            cursor = buffer.index(cursor, offsetBy: length)
        }

        let target = String(parts[1])
        let components = URLComponents(string: target.hasPrefix("/") ? "http://localhost\(target)" : target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(method: String(parts[0]).uppercased(),
                                  path: components?.percentEncodedPath ?? target,
                                  query: query, headers: headers, body: body)
        let keepAlive = headers["connection"]?.lowercased() != "close" && parts[2] == "HTTP/1.1"
        buffer = Data(buffer[cursor...])
        return .request(request, keepAlive: keepAlive)
    }
}
