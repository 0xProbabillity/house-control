import AppKit
import WebKit

/// Regular window hosting the home editor (rooms, devices, Smart Life links).
final class EditorController: NSObject, NSWindowDelegate {
    let host: WebHost
    let window: NSWindow
    var onClose: (() -> Void)?
    /// The plan in the editor differs from the saved one (the page reports it, see `editorDirty`).
    private(set) var isDirty = false

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

    func setDirty(_ dirty: Bool) {
        isDirty = dirty
        window.isDocumentEdited = dirty // the dot in the close button
    }

    /// The close button and ⌘W ask first while there are unsaved changes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        confirmUnsaved { [weak self] proceed in
            if proceed { self?.window.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// Save / Cancel / Discard, as a sheet on the editor. `done(true)` once the changes are saved
    /// (exactly as “Save & apply” does) or discarded; `done(false)` when the user cancels or the
    /// save fails (the editor then says why). Not called while the question is already up.
    func confirmUnsaved(_ done: @escaping (Bool) -> Void) {
        guard isDirty else { done(true); return }
        show()
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Save the changes to this home?"
        alert.informativeText = "Your edits to the plan are not saved yet. If you don’t save them, they are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Discard")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        if #available(macOS 11.0, *) { discard.hasDestructiveAction = true }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.host.webView.callAsyncJavaScript("return await window.house.saveForClose()", arguments: [:],
                                                      in: nil, in: .page) { [weak self] result in
                    if case .success(let saved) = result, saved as? Bool == true {
                        self?.setDirty(false)
                        done(true)
                    } else {
                        done(false)
                    }
                }
            case .alertThirdButtonReturn:
                self.setDirty(false)
                done(true)
            default:
                done(false)
            }
        }
    }
}
