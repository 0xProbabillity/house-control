import AppKit
import WebKit

/// Serves the bundled web UI under `house://app/…` so ES modules, fetch and
/// localStorage behave as they would on a normal origin.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "house"
    private let root: URL

    init(root: URL) { self.root = root }

    private static let mime: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg",
        "woff2": "font/woff2", "map": "application/json",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
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

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// A WKWebView showing the web UI in one of its modes ("panel" or "editor"),
/// plus the JSON message bridge in both directions.
final class WebHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    let mode: String
    var onMessage: (([String: Any]) -> Void)?
    private var bootProvider: () -> [String: Any]

    /// Where the web UI lives: the app bundle, or a directory / dev server given by the environment.
    static var assetRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["HOUSE_WEB_DIR"] { return URL(fileURLWithPath: dir) }
        return (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("web")
    }

    init(mode: String, transparent: Bool, boot: @escaping () -> [String: Any]) {
        self.mode = mode
        self.bootProvider = boot
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AssetSchemeHandler(root: Self.assetRoot), forURLScheme: AssetSchemeHandler.scheme)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // A run against a throw-away data folder must not touch the saved panel state either.
        if ProcessInfo.processInfo.environment["HOUSE_DATA_DIR"] != nil { config.websiteDataStore = .nonPersistent() }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "house")
        webView.navigationDelegate = self
        if transparent {
            webView.setValue(false, forKey: "drawsBackground")
            if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        }
        webView.allowsMagnification = false
    }

    func load() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        var boot = bootProvider()
        boot["mode"] = mode
        let json = Self.json(boot)
        controller.addUserScript(WKUserScript(source: "window.__HOUSE_BOOT__ = \(json);",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let base = ProcessInfo.processInfo.environment["HOUSE_DEV_URL"] ?? "\(AssetSchemeHandler.scheme)://app/index.html"
        webView.load(URLRequest(url: URL(string: "\(base)?mode=\(mode)")!))
    }

    /// Calls `window.house.<function>(…args)` in the page.
    func call(_ function: String, _ args: Any...) {
        let list = args.map { Self.json($0) }.joined(separator: ",")
        webView.evaluateJavaScript("window.house && window.house.\(function) && window.house.\(function)(\(list));", completionHandler: nil)
    }

    func reply(to message: [String: Any], _ result: Any) {
        guard let id = message["callId"] as? Int else { return }
        call("reply", id, result)
    }

    static func json(_ value: Any) -> String {
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

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        onMessage?(body)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The UI never navigates away; anything external opens in the default browser.
        if let url = action.request.url, let scheme = url.scheme,
           ["http", "https"].contains(scheme), url.host != "localhost", action.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
