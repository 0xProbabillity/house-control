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
    private static let canvasWidth: CGFloat = 820
    private static let shadowRoom: CGFloat = 178 // the canvas below the open island: 470 - 292
    private static let ear: CGFloat = 64
    private static let heightKey = "islandOpenHeight"

    /// How tall the open island is. The owner stretches it by its bottom edge; it is kept
    /// across launches.
    private(set) var openHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: IslandController.heightKey)
        return max(IslandController.open.height, saved > 0 ? CGFloat(saved) : IslandController.open.height)
    }()
    private var canvasSize: NSSize { NSSize(width: Self.canvasWidth, height: openHeight + Self.shadowRoom) }

    let host: WebHost
    private let window: IslandPanel
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    /// The notch in screen coordinates (the drawn one on a display that has none).
    private var notch = NSRect.zero
    private var hasNotch = false
    private(set) var isExpanded = false
    private(set) var isShown = false
    /// While the full panel is up the island stays closed (it would hang over the panel's top edge).
    var suspended = false {
        didSet { if suspended { pending?.cancel(); pending = nil; setExpanded(false) } }
    }
    /// The notch (or the drawn tab) in screen coordinates, and the display it is on.
    var anchor: (rect: NSRect, screen: NSScreen?) { (notch, window.screen) }
    /// HOUSE_ISLAND_EXPANDED=1 keeps it open (screenshots).
    private let pinned = ProcessInfo.processInfo.environment["HOUSE_ISLAND_EXPANDED"] != nil
    var onExpandedChange: ((Bool) -> Void)?

    init(host: WebHost) {
        self.host = host
        window = IslandPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: Self.canvasWidth, height: openHeight + Self.shadowRoom)),
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
        ["notchWidth": Double(notch.width), "notchHeight": Double(notch.height), "hasNotch": hasNotch, "expanded": pinned,
         "openHeight": Double(openHeight)]
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
        let size = canvasSize
        window.setFrame(NSRect(x: (notch.midX - size.width / 2).rounded(), y: frame.maxY - size.height,
                               width: size.width, height: size.height), display: true)
    }

    /// Called while the owner drags the island's bottom edge; keeps the island inside the screen.
    func setOpenHeight(_ value: CGFloat, final: Bool = false) {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let room = (screen?.frame.height ?? 900) - notch.height - Self.shadowRoom - 40
        let clamped = min(max(value, Self.open.height), max(Self.open.height, room))
        if clamped != openHeight {
            openHeight = clamped
            if isShown { place() }
        }
        if final { UserDefaults.standard.set(Double(openHeight), forKey: Self.heightKey) }
    }

    private func pointerMoved() {
        guard isShown, !pinned, !suspended else { return }
        let point = NSEvent.mouseLocation
        if isExpanded {
            if NSEvent.pressedMouseButtons & 1 != 0 { return } // dragging the edge must not close it
            let zone = NSRect(x: notch.midX - Self.open.width / 2 - 14, y: notch.minY - openHeight - 18,
                              width: Self.open.width + 28, height: notch.height + openHeight + 18 + 2)
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
