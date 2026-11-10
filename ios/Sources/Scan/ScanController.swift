#if ROOM_SCAN
import SwiftUI
import ARKit
import RoomPlan
import OSLog
import HouseCore

/// One LiDAR scan of a home, room by room, in one AR session, so every room and every lamp
/// pointed at shares one world. RoomPlan draws the live outline; the pins of the tagged
/// devices are an overlay of our own (`ScanOverlayView`). Each finished room is processed in
/// the background while the next one is scanned, then dropped down to plain numbers
/// (`RoomScan`), so memory stays flat however many rooms there are.
@MainActor
@Observable
final class ScanController {
    enum Phase: Equatable {
        case scanning
        /// The last rooms are being processed and the plan drawn.
        case building
        case review
        case failed(String)
    }

    struct Note: Equatable, Identifiable {
        let id = UUID()
        var symbol: String
        var text: String
    }

    let homeName: String
    private(set) var phase: Phase = .scanning
    /// Rooms finished and processed.
    private(set) var roomsDone = 0
    /// True while RoomPlan is capturing a room.
    private(set) var capturing = false
    /// Between two rooms: the last is being handed over and the next starts by itself.
    private(set) var switching = false
    /// The capture stopped on its own (the app left the screen, tracking was lost):
    /// a button carries on with a new room.
    private(set) var interrupted: String?
    private(set) var tags: [RoomScan.Tag] = []
    private(set) var note: Note?
    private(set) var hot = false
    /// The tag whose device is being chosen.
    var picking: RoomScan.Tag?
    /// The plan made from the scan, once `phase` is `.review`.
    private(set) var plan: [String: Any]?
    let catalog = DeviceCatalog()

    @ObservationIgnored let session = ARSession()
    @ObservationIgnored private var captureView: RoomCaptureView?
    @ObservationIgnored private let delegate = CaptureDelegate()
    @ObservationIgnored private(set) weak var overlay: ScanOverlayView?
    @ObservationIgnored private var rooms: [RoomScan.Room] = []
    @ObservationIgnored private var processing = 0
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    @ObservationIgnored private var thermal: NSObjectProtocol?
    @ObservationIgnored private let saveURL: URL?
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HouseControl", category: "scan")

    static var isSupported: Bool { RoomCaptureSession.isSupported || previewing }

    /// HOUSE_SCAN_PREVIEW=1 in a debug build: the scanning screen without a camera (the
    /// simulator has none), to look at its controls and the device picker.
    static var previewing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["HOUSE_SCAN_PREVIEW"] == "1" && !RoomCaptureSession.isSupported
        #else
        false
        #endif
    }

    /// `saveURL`: where the raw scan is kept, so a plan can be made from it again.
    init(homeName: String, saveURL: URL?) {
        self.homeName = homeName
        self.saveURL = saveURL
        delegate.onData = { [weak self] data, error in self?.received(data, error: error) }
    }

    /// A scan read back from a file (`HOUSE_SCAN_FIXTURE`): straight to its review.
    init(homeName: String, replaying scan: RoomScan) {
        self.homeName = homeName
        saveURL = nil
        rooms = scan.rooms
        tags = scan.tags
        roomsDone = scan.rooms.count
        makePlan()
    }

    // MARK: - Capture

    /// The view RoomPlan draws the camera and the outline in, with the pins on top.
    func makeView() -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        guard RoomCaptureSession.isSupported else {
            if Self.previewing {
                let overlay = ScanOverlayView(session: session)
                overlay.frame = container.bounds
                overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(overlay)
                self.overlay = overlay
            }
            return container
        }
        let capture = RoomCaptureView(frame: .zero, arSession: session)
        capture.delegate = delegate
        capture.translatesAutoresizingMaskIntoConstraints = false
        let overlay = ScanOverlayView(session: session)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onTap = { [weak self] point in self?.tag(at: point) }
        overlay.onChoose = { [weak self] id in self?.choose(id) }
        overlay.onRemove = { [weak self] id in self?.remove(id) }
        container.addSubview(capture)
        container.addSubview(overlay)
        for view in [capture, overlay] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        captureView = capture
        self.overlay = overlay
        overlay.show(tags)
        return container
    }

    func start() {
        if Self.previewing {
            capturing = true
            return
        }
        guard Self.isSupported, phase == .scanning, !capturing, let captureView else { return }
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
        capturing = true
        interrupted = nil
        UIApplication.shared.isIdleTimerDisabled = true
        if thermal == nil {
            thermal = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.thermalChanged() }
            }
            thermalChanged()
        }
    }

    /// Finishes this room and starts the next in the same session, so they line up.
    func nextRoom() {
        if Self.previewing {
            roomsDone += 1
            show("checkmark.circle.fill", "Room \(roomsDone) saved · scan the next one")
            return
        }
        guard capturing, !switching else { return }
        switching = true
        capturing = false
        captureView?.captureSession.stop(pauseARSession: false)
        Haptics.shared.play("medium")
    }

    /// Carries on after the capture stopped by itself.
    func resume() {
        interrupted = nil
        start()
    }

    /// Ends the scan: the last room is processed, then the plan drawn.
    func finish() {
        guard phase == .scanning else { return }
        finishing = true
        phase = .building
        Haptics.shared.play("success")
        if capturing {
            capturing = false
            captureView?.captureSession.stop()
        } else if !switching, processing == 0 {
            makePlan()
        }
        // A capture that never reports back must not leave the screen spinning.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.phase == .building, self.plan == nil else { return }
            self.processing = 0
            self.makePlan()
        }
    }

    /// Leaves the scan: the camera and the session stop.
    func close() {
        if capturing { captureView?.captureSession.stop() }
        capturing = false
        session.pause()
        overlay?.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if let thermal { NotificationCenter.default.removeObserver(thermal) }
        thermal = nil
    }

    /// A room's capture ended: by "Next room", by "Done", or by itself.
    private func received(_ data: CapturedRoomData, error: Error?) {
        if let error { Self.log.error("capture ended: \(error.localizedDescription, privacy: .public)") }
        let wasSwitching = switching
        switching = false
        capturing = false
        process(data)
        if finishing { return }
        if wasSwitching {
            show("checkmark.circle.fill", "Room \(rooms.count + processing) saved · scan the next one")
            // The next room starts once this one has let go of the session.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.start()
            }
        } else {
            interrupted = Self.message(for: error)
            Haptics.shared.play("error")
        }
    }

    private func process(_ data: CapturedRoomData) {
        processing += 1
        Task { [weak self] in
            let room = await Self.build(data)
            guard let self else { return }
            self.processing -= 1
            if let room, !room.walls.isEmpty {
                self.rooms.append(room)
                self.roomsDone = self.rooms.count
            } else if !self.finishing {
                self.show("exclamationmark.triangle.fill", "Too little of that room was seen to use it")
            }
            if self.finishing, self.processing == 0, self.phase == .building, self.plan == nil { self.makePlan() }
        }
    }

    /// RoomPlan's own clean-up of a room (square corners, tidy furniture), off the main thread.
    nonisolated private static func build(_ data: CapturedRoomData) async -> RoomScan.Room? {
        do {
            let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
            return RoomScan.Room(room)
        } catch {
            log.error("room not built: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func makePlan() {
        let scan = RoomScan(rooms: rooms, tags: tags)
        if let saveURL, let data = try? JSONEncoder().encode(scan) { try? data.write(to: saveURL, options: .atomic) }
        guard let plan = ScanLayout.plan(from: scan, name: homeName) else {
            phase = .failed(rooms.isEmpty
                ? "No room was scanned far enough to draw. Walk along every wall of the room, pointing the camera at it, then tap Done."
                : "The rooms scanned are too small to draw. Scan each room wall to wall.")
            return
        }
        self.plan = plan
        phase = .review
        close()
    }

    private static func message(for error: Error?) -> String {
        switch error as? RoomCaptureSession.CaptureError {
        case .worldTrackingFailure: "The camera lost track of the room."
        case .deviceTooHot: "The iPhone got too warm to scan. Let it cool down a little."
        case .exceedSceneSizeLimit: "This room is as big as one scan can be. Tap Done, or carry on with the next room."
        default: "Scanning paused."
        }
    }

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        hot = state == .serious || state == .critical
        // Better a finished home than a scan the system stops halfway.
        if state == .critical, phase == .scanning, !rooms.isEmpty || capturing {
            show("thermometer.high", "The iPhone is too warm: finishing the scan")
            finish()
        }
    }

    // MARK: - Devices

    /// Pins a device where the screen point (the middle, by default) meets the room. Its kind
    /// is guessed from where it is: high on a wall is an AC, anything else a lamp.
    func tag(at point: CGPoint? = nil) {
        if Self.previewing {
            let tag = RoomScan.Tag(kind: "light", name: Self.genericName("light"), position: RoomScan.Point(x: 0, y: 0, z: -1))
            tags.append(tag)
            picking = tag
            return
        }
        guard phase == .scanning, capturing || switching, let overlay, let frame = session.currentFrame else {
            if phase == .scanning { show("hand.point.up.left.fill", "Start scanning first") }
            return
        }
        let size = overlay.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let target = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let camera = frame.camera.transform.columns.3
        var position: simd_float3
        var kind = "light"
        let normalized = CGPoint(x: target.x / size.width, y: target.y / size.height)
        let image = normalized.applying(frame.displayTransform(for: .portrait, viewportSize: size).inverted())
        let query = frame.raycastQuery(from: image, allowing: .estimatedPlane, alignment: .any)
        if let hit = session.raycast(query).first {
            let t = hit.worldTransform
            position = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let normal = simd_float3(t.columns.1.x, t.columns.1.y, t.columns.1.z)
            if abs(normal.y) < 0.5, position.y > camera.y + 0.35 { kind = "ac" }
        } else {
            // Nothing to hit (a bare, dark or far surface): a metre and a half ahead.
            let forward = -simd_float3(frame.camera.transform.columns.2.x, frame.camera.transform.columns.2.y,
                                       frame.camera.transform.columns.2.z)
            position = simd_float3(camera.x, camera.y, camera.z) + simd_normalize(forward) * 1.5
        }
        let tag = RoomScan.Tag(kind: kind, name: Self.genericName(kind), position: RoomScan.Point(position))
        tags.append(tag)
        overlay.show(tags)
        Haptics.shared.play("medium")
        picking = tag
    }

    static func genericName(_ kind: String) -> String { kind == "ac" ? "Air conditioner" : "Lamp" }

    /// Sets what a pin is: a real device, or a lamp or AC to link later.
    func assign(_ id: String, kind: String, device: RealDevice?) {
        guard let i = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[i].kind = device?.kind ?? kind
        tags[i].name = device?.name ?? Self.genericName(kind)
        tags[i].device = device.flatMap { RoomScan.Device($0.raw) }
        overlay?.show(tags)
        Haptics.shared.play("success")
    }

    func remove(_ id: String) {
        tags.removeAll { $0.id == id }
        if picking?.id == id { picking = nil }
        overlay?.show(tags)
        Haptics.shared.play("light")
    }

    private func choose(_ id: String) {
        picking = tags.first { $0.id == id }
    }

    /// Real devices already given to a pin, so the list can say so.
    var taggedDevices: [PlanEditor.DeviceRef: String] {
        var out: [PlanEditor.DeviceRef: String] = [:]
        for tag in tags { if let d = tag.device { out[.init(service: d.service, id: d.id)] = tag.name } }
        return out
    }

    // MARK: - Notes

    func show(_ symbol: String, _ text: String) {
        noteTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { note = Note(symbol: symbol, text: text) }
        noteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { self?.note = nil }
        }
    }
}

/// RoomCaptureView wants an NSCoding delegate; this one only hands the captured room on.
/// Returning false keeps RoomPlan's own result screen away: the rooms go to our review.
@objc(HouseScanCaptureDelegate)
final class CaptureDelegate: NSObject, RoomCaptureViewDelegate {
    var onData: (@MainActor (CapturedRoomData, Error?) -> Void)?

    override init() { super.init() }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        let data = roomDataForProcessing
        let failure = error
        Task { @MainActor [onData] in onData?(data, failure) }
        return false
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {}
}

/// The pins of the tagged devices, kept over the spot in the room they were put on as the
/// camera moves. Plain UIKit moved once per frame by a display link: no SwiftUI state changes
/// per frame, and no AR frame is kept past the tick that reads it.
final class ScanOverlayView: UIView {
    var onTap: ((CGPoint) -> Void)?
    var onChoose: ((String) -> Void)?
    var onRemove: ((String) -> Void)?
    private weak var session: ARSession?
    private var pins: [String: PinView] = [:]
    private var positions: [String: simd_float3] = [:]
    private var link: CADisplayLink?

    init(session: ARSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        onTap?(gesture.location(in: self))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func show(_ tags: [RoomScan.Tag]) {
        let ids = Set(tags.map(\.id))
        for (id, pin) in pins where !ids.contains(id) {
            UIView.animate(withDuration: 0.2, animations: { pin.alpha = 0 }) { _ in pin.removeFromSuperview() }
            pins[id] = nil
            positions[id] = nil
        }
        for tag in tags {
            positions[tag.id] = simd_float3(Float(tag.position.x), Float(tag.position.y), Float(tag.position.z))
            let pin = pins[tag.id] ?? {
                let pin = PinView()
                pin.isHidden = true
                addSubview(pin)
                pins[tag.id] = pin
                pin.pop()
                return pin
            }()
            pin.configure(tag, choose: { [weak self] in self?.onChoose?(tag.id) }, remove: { [weak self] in self?.onRemove?(tag.id) })
        }
        tick()
    }

    @objc private func tick() {
        guard !pins.isEmpty, let frame = session?.currentFrame else { return }
        let camera = frame.camera
        let view = camera.viewMatrix(for: .portrait)
        let size = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, pin) in pins {
            guard let p = positions[id] else { continue }
            let local = view * simd_float4(p, 1)
            // Behind the camera, or right on it.
            guard local.z < -0.15 else { pin.isHidden = true; continue }
            let screen = camera.projectPoint(p, orientation: .portrait, viewportSize: size)
            guard screen.x > -80, screen.x < size.width + 80, screen.y > -40, screen.y < size.height + 120 else {
                pin.isHidden = true
                continue
            }
            pin.isHidden = false
            pin.place(at: screen, distance: -local.z)
        }
        CATransaction.commit()
    }
}

/// A capsule with the device's symbol and name over a dot where it is; tapping it offers to
/// choose the device or to take the pin away.
private final class PinView: UIView {
    private let button = UIButton(configuration: .filled())
    private let dot = UIView()
    private let stem = UIView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 160, height: 64))
        isUserInteractionEnabled = true
        stem.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 6
        dot.layer.borderWidth = 2.5
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.5
        dot.layer.shadowRadius = 4
        dot.layer.shadowOffset = .zero
        button.showsMenuAsPrimaryAction = true
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.45
        button.layer.shadowRadius = 10
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(stem)
        addSubview(dot)
        addSubview(button)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ tag: RoomScan.Tag, choose: @escaping () -> Void, remove: @escaping () -> Void) {
        let ac = tag.kind == "ac"
        let tint = ac ? UIColor(Theme.accent) : UIColor(Theme.warm)
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 0.86)
        config.baseForegroundColor = .white
        config.image = UIImage(systemName: ac ? "air.conditioner.horizontal.fill" : "lightbulb.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        config.imagePadding = 6
        config.imageColorTransformer = UIConfigurationColorTransformer { _ in tint }
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 12)
        var title = AttributedString(tag.name)
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        config.attributedTitle = title
        if let device = tag.device {
            var subtitle = AttributedString(ConnectionLook.title(device.service))
            subtitle.font = .systemFont(ofSize: 11, weight: .medium)
            subtitle.foregroundColor = UIColor.white.withAlphaComponent(0.6)
            config.attributedSubtitle = subtitle
        }
        button.configuration = config
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.menu = UIMenu(title: tag.name, children: [
            UIAction(title: tag.device == nil ? "Choose the device…" : "Change the device…", image: UIImage(systemName: "link")) { _ in choose() },
            UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in remove() },
        ])
        button.accessibilityLabel = "\(tag.name), pinned"
        dot.layer.borderColor = tint.cgColor
        let fitted = button.systemLayoutSizeFitting(CGSize(width: 220, height: 60))
        let width = min(220, max(60, fitted.width))
        bounds = CGRect(x: 0, y: 0, width: width, height: fitted.height + 30)
        button.frame = CGRect(x: 0, y: 0, width: width, height: fitted.height)
        stem.frame = CGRect(x: width / 2 - 1, y: fitted.height, width: 2, height: 18)
        dot.frame = CGRect(x: width / 2 - 6, y: fitted.height + 16, width: 12, height: 12)
    }

    /// Puts the dot on `point`, fading pins far away.
    func place(at point: CGPoint, distance: Float) {
        center = CGPoint(x: point.x, y: point.y - bounds.height / 2 + 8)
        alpha = distance > 7 ? 0.55 : 1
    }

    func pop() {
        transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.8) {
            self.transform = .identity
        }
    }
}
#endif
