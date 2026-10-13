import Foundation
import WebKit

/// Serves the bundled web UI under `house://app/…` so ES modules, fetch and
/// localStorage behave as they would on a normal origin.
public final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "house"
    public static let indexURL = "\(scheme)://app/index.html"
    private let root: URL

    public init(root: URL) { self.root = root }

    private static let mime: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg",
        "woff2": "font/woff2", "map": "application/json",
    ]

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(response)
            task.didReceive(Data())
            task.didFinish()
            return
        }
        let type = Self.mime[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type.hasPrefix("text/") || type.hasSuffix("json") ? "\(type); charset=utf-8" : type,
            "Content-Length": String(data.count),
            "Cache-Control": "no-cache",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// JSON literals for the bridge into the web UI.
public enum WebJSON {
    /// `value` as JavaScript source: an object, an array or a scalar.
    public static func literal(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) {
            return String(data: data, encoding: .utf8) ?? "null"
        }
        // Scalars are not valid top-level JSON objects: wrap, encode, unwrap.
        if let data = try? JSONSerialization.data(withJSONObject: [value]), let s = String(data: data, encoding: .utf8) {
            return String(s.dropFirst().dropLast())
        }
        return "null"
    }

    /// `window.house.<function>(…args)`, guarded so a page that is still loading ignores it.
    public static func call(_ function: String, _ args: [Any]) -> String {
        let list = args.map(literal).joined(separator: ",")
        return "window.house && window.house.\(function) && window.house.\(function)(\(list));"
    }
}
