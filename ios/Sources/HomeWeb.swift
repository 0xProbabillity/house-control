import SwiftUI
import WebKit
import OSLog
import HouseCore

/// A WKWebView showing the web UI, plus the JSON bridge in both directions: the 3D home and
/// its panel ("panel", the same page the Mac shows in its menu bar popover) or the home
/// editor ("editor", the Mac's editor window laid out for a phone).
@MainActor
final class HomeWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let mode: String
    var onMessage: (([String: Any]) -> Void)?
    private let configuration: WKWebViewConfiguration
    private var view: WKWebView?
    private var boot: (() -> [String: Any])?
    /// Set by the page's "ready" message; a load that never gets there is retried.
    private var ready = false
    private var retries = 0
    private var watchdog: DispatchWorkItem?

    /// The built web UI inside the app bundle.
    static var assetRoot: URL {
        (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("dist")
    }

    init(persistent: Bool, mode: String = "panel") {
        self.mode = mode
        configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AssetSchemeHandler(root: Self.assetRoot), forURLScheme: AssetSchemeHandler.scheme)
        configuration.allowsInlineMediaPlayback = true
        // A run against a throw-away data folder must not touch the saved panel state either.
        if !persistent { configuration.websiteDataStore = .nonPersistent() }
        super.init()
        configuration.userContentController.add(self, name: "house")
    }

    /// The web view, made the first time SwiftUI puts it on screen. One made earlier, before the
    /// app has its window (the model is created at launch), aborts the app on the first touch on
    /// iOS 17: UIKit's gesture graph misses a node for WebKit's gestures
    /// ("Invalid parameter not satisfying: targetNode").
    var webView: WKWebView {
        if let view { return view }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Theme.background)
        webView.scrollView.backgroundColor = UIColor(Theme.background)
        webView.scrollView.isScrollEnabled = false
        // The page keeps text fields from zooming it in (`maximum-scale=1` in index.html).
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        view = webView
        if boot != nil { reload() }
        return webView
    }

    /// Loads the page now if the web view is on screen, else as soon as it is.
    func load(boot: @escaping () -> [String: Any]) {
        self.boot = boot
        if view != nil { reload() }
    }

    func reload() {
        guard let view, let boot else { return }
        let controller = configuration.userContentController
        controller.removeAllUserScripts()
        var payload = boot()
        payload["mode"] = mode
        payload["platform"] = "ios"
        controller.addUserScript(WKUserScript(source: "window.__HOUSE_BOOT__ = \(WebJSON.literal(payload));",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.errorReporter, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view.load(URLRequest(url: URL(string: "\(AssetSchemeHandler.indexURL)?mode=\(mode)")!))

        // Right after a cold boot WebKit's processes can be slow enough to drop the first
        // load; a page that has not reported in is loaded again, a couple of times at most.
        ready = false
        watchdog?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, !self.ready, self.retries < 2 else { return }
            self.retries += 1
            self.reload()
        }
        watchdog = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: check)
    }

    /// Script errors in the page end up in the device log (Console.app, `log stream`).
    private static let errorReporter = """
        (() => {
          const tell = (text) => window.webkit.messageHandlers.house.postMessage({ type: 'log', text: String(text) });
          window.addEventListener('error', (e) => tell(`${e.message} (${(e.filename || '').split('/').pop()}:${e.lineno})`), true);
          window.addEventListener('unhandledrejection', (e) => tell(`unhandled: ${e.reason && e.reason.message || e.reason}`));
        })();
        """

    /// Stops the page from talking back (the message handler holds on to this object).
    func detach() {
        watchdog?.cancel()
        configuration.userContentController.removeScriptMessageHandler(forName: "house")
        view?.stopLoading()
    }

    /// Calls `window.house.<function>(…args)` in the page.
    func call(_ function: String, _ args: Any...) {
        view?.evaluateJavaScript(WebJSON.call(function, args), completionHandler: nil)
    }

    func reply(to message: [String: Any], _ result: Any) {
        guard let id = message["callId"] as? Int else { return }
        call("reply", id, result)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }
            if body["type"] as? String == "log" {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "HouseControl", category: "web-\(mode)").error("\(body["text"] as? String ?? "", privacy: .public)")
                return
            }
            if body["type"] as? String == "ready" {
                ready = true
                retries = 0
            }
            onMessage?(body)
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            // The UI never navigates away; anything external opens in Safari.
            if let url = action.request.url, let scheme = url.scheme, ["http", "https"].contains(scheme),
               action.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    /// iOS may discard the page's process while the app is in the background.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { reload() }
    }
}

struct HomeWebView: UIViewRepresentable {
    let web: HomeWeb

    func makeUIView(context: Context) -> WKWebView { web.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
