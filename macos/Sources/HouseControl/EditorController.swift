import AppKit
import WebKit

/// Regular window hosting the home editor (rooms, devices, Smart Life links).
final class EditorController: NSObject, NSWindowDelegate {
    let host: WebHost
    private let window: NSWindow
    var onClose: (() -> Void)?

    init(host: WebHost) {
        self.host = host
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "House Control — Edit Home"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed: 0.04, green: 0.055, blue: 0.1, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = host.webView
        window.center()
        window.setFrameAutosaveName("HouseControlEditor")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
