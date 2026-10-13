import AppKit
import HouseCore

/// A small window around one QR code: the pairing code for an iPhone, or the Smart Life
/// login code a paired iPhone asked this Mac to display.
@MainActor
final class QRWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let image = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let dot = NSView()
    private let buttons = NSStackView()
    private var actions: [() -> Void] = []
    var onClose: (() -> Void)?

    init(title: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedRed: 0.04, green: 0.055, blue: 0.1, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self

        // The code itself sits on a white card: scanners need the quiet zone around it.
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 22
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(image)

        headline.font = .systemFont(ofSize: 17, weight: .semibold)
        headline.alignment = .center
        detail.font = .systemFont(ofSize: 12.5)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        status.font = .systemFont(ofSize: 12.5, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.preferredMaxLayoutWidth = 290
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        let statusRow = NSStackView(views: [dot, status])
        statusRow.spacing = 7
        statusRow.alignment = .firstBaseline
        buttons.spacing = 10

        let stack = NSStackView(views: [headline, card, detail, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.setCustomSpacing(12, after: detail)
        stack.edgeInsets = NSEdgeInsets(top: 46, left: 30, bottom: 26, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 380),
            card.widthAnchor.constraint(equalToConstant: 268),
            card.heightAnchor.constraint(equalToConstant: 268),
            image.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            image.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            image.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            image.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            detail.widthAnchor.constraint(equalToConstant: 320),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        setStatus("", active: false)
    }

    func addButton(_ title: String, action: @escaping () -> Void) {
        let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.tag = actions.count
        actions.append(action)
        buttons.addArrangedSubview(button)
    }

    @objc private func pressed(_ sender: NSButton) { actions[sender.tag]() }

    func show(code: String, headline text: String, detail more: String) {
        if let cg = QRCode.image(for: code, scale: 12) {
            image.image = NSImage(cgImage: cg, size: NSSize(width: 232, height: 232))
        }
        headline.stringValue = text
        detail.stringValue = more
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func setStatus(_ text: String, active: Bool) {
        status.stringValue = text
        dot.isHidden = text.isEmpty
        dot.layer?.backgroundColor = (active ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
