import AppKit
import WebKit
import HouseCore

/// Takes the click that reaches a window which is not the key one (the island never is:
/// hovering the notch must not steal the keyboard from the app you are typing in).
private final class FirstMouseWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A WKWebView showing the web UI in one of its modes ("panel", "editor", "island" or "agent"),
/// plus the JSON message bridge in both directions.
final class WebHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    let mode: String
    var onMessage: (([String: Any]) -> Void)?
    /// True once the page has started and reported "ready"; false again while it reloads.
    private(set) var isReady = false
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
        webView = FirstMouseWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "house")
        webView.navigationDelegate = self
        if transparent {
            webView.setValue(false, forKey: "drawsBackground")
            if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        }
        webView.allowsMagnification = false
        // WebKit stops rendering into windows the system reports as hidden, which is every
        // window while the screen is locked. HOUSE_RENDER_HIDDEN=1 keeps the page drawing
        // there, so captures can be taken on an unattended Mac.
        if ProcessInfo.processInfo.environment["HOUSE_RENDER_HIDDEN"] != nil,
           webView.responds(to: Selector(("_setWindowOcclusionDetectionEnabled:"))) {
            webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
    }

    func load() {
        isReady = false
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        var boot = bootProvider()
        boot["mode"] = mode
        let json = WebJSON.literal(boot)
        controller.addUserScript(WKUserScript(source: "window.__HOUSE_BOOT__ = \(json);",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.errorReporter, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let base = ProcessInfo.processInfo.environment["HOUSE_DEV_URL"] ?? AssetSchemeHandler.indexURL
        webView.load(URLRequest(url: URL(string: "\(base)?mode=\(mode)")!))
    }

    /// Writes a PNG of what the page shows. Works for a window that is not on screen,
    /// which a screen capture does not.
    func snapshot(to url: URL) {
        webView.takeSnapshot(with: nil) { image, _ in
            guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Script errors in the page are written to the app's log (stderr, Console.app).
    private static let errorReporter = """
        (() => {
          const tell = (text) => window.webkit.messageHandlers.house.postMessage({ type: 'log', text: String(text) });
          window.addEventListener('error', (e) => tell(`${e.message} (${(e.filename || '').split('/').pop()}:${e.lineno})`), true);
          window.addEventListener('unhandledrejection', (e) => tell(`unhandled: ${e.reason && e.reason.message || e.reason}`));
        })();
        """

    /// Calls `window.house.<function>(…args)` in the page.
    func call(_ function: String, _ args: Any...) {
        webView.evaluateJavaScript(WebJSON.call(function, args), completionHandler: nil)
    }

    func reply(to message: [String: Any], _ result: Any) {
        guard let id = message["callId"] as? Int else { return }
        call("reply", id, result)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "log" {
            NSLog("House Control web (%@): %@", mode, body["text"] as? String ?? "")
            return
        }
        if body["type"] as? String == "ready" { isReady = true }
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
