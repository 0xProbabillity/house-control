import AppKit
import WebKit

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The island: a transparent window pinned to the top of the screen, around the MacBook's
/// notch. The web content draws a black tab there that shows what is on, springs open
/// under the pointer and peeks out when something changes. A display without a notch
/// gets a drawn one in the middle of its menu bar.
@MainActor
final class IslandController: NSObject {
    // Must match island.css: the open island below the notch, and room for its shadow.
    private static let open = NSSize(width: 664, height: 292)
    private static let canvas = NSSize(width: 820, height: 470)
    private static let ear: CGFloat = 64

    let host: WebHost
    private let window: IslandPanel
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    /// The notch in screen coordinates (the drawn one on a display that has none).
    private var notch = NSRect.zero
    private var hasNotch = false
    private(set) var isExpanded = false
    private(set) var isShown = false
    /// HOUSE_ISLAND_EXPANDED=1 keeps it open (screenshots).
    private let pinned = ProcessInfo.processInfo.environment["HOUSE_ISLAND_EXPANDED"] != nil
    var onExpandedChange: ((Bool) -> Void)?

    init(host: WebHost) {
        self.host = host
        window = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.canvas),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2) // over the menu bar
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.contentView = host.webView
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// What the web side needs to draw itself around the notch.
    var bootInfo: [String: Any] {
        ["notchWidth": Double(notch.width), "notchHeight": Double(notch.height), "hasNotch": hasNotch, "expanded": pinned]
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        place()
        host.load()
        window.orderFrontRegardless()
        // Watching the pointer needs no permission; nothing is read but its position.
        let moved: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { moved($0); return $0 }) {
            monitors.append(local)
        }
        if pinned { setExpanded(true) }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pending?.cancel()
        setExpanded(false)
        window.orderOut(nil)
    }

    @objc private func screensChanged() {
        guard isShown else { return }
        let before = (notch.size, hasNotch)
        place()
        if before != (notch.size, hasNotch) { host.load() }
    }

    /// Picks the display (the one with a notch if there is one) and pins the window to its top.
    private func place() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notch = NSRect(x: left.maxX, y: frame.maxY - screen.safeAreaInsets.top,
                           width: max(120, right.minX - left.maxX), height: screen.safeAreaInsets.top)
        } else {
            hasNotch = false
            let bar = frame.maxY - screen.visibleFrame.maxY
            let height = bar > 10 ? bar : 28
            notch = NSRect(x: frame.midX - 95, y: frame.maxY - height, width: 190, height: height)
        }
        // A real notch is black in full-screen spaces anyway; a drawn one would cover a film.
        window.collectionBehavior = hasNotch ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                                             : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.setFrame(NSRect(x: (notch.midX - Self.canvas.width / 2).rounded(), y: frame.maxY - Self.canvas.height,
                               width: Self.canvas.width, height: Self.canvas.height), display: true)
    }

    private func pointerMoved() {
        guard isShown, !pinned else { return }
        let point = NSEvent.mouseLocation
        if isExpanded {
            let zone = NSRect(x: notch.midX - Self.open.width / 2 - 14, y: notch.minY - Self.open.height - 18,
                              width: Self.open.width + 28, height: notch.height + Self.open.height + 18 + 2)
            schedule(zone.contains(point) ? nil : false, after: 0.32)
        } else {
            let zone = notch.insetBy(dx: -Self.ear, dy: 0).offsetBy(dx: 0, dy: 1)
            schedule(zone.contains(point) ? true : nil, after: 0.09)
        }
    }

    /// Opens or closes after a short dwell, so brushing past the notch does nothing; nil cancels.
    private func schedule(_ expand: Bool?, after delay: TimeInterval) {
        guard let expand else {
            pending?.cancel()
            pending = nil
            return
        }
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.setExpanded(expand)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setExpanded(_ on: Bool) {
        guard on != isExpanded else { return }
        isExpanded = on
        window.ignoresMouseEvents = !on
        host.call("islandState", on ? "expanded" : "collapsed")
        onExpandedChange?(on)
    }
}
