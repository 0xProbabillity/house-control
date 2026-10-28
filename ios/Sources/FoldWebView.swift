import UIKit
import WebKit

/// The web view, telling the page where a folding screen (iPhone Duo) breaks in two, so the
/// 3D home and the controls each keep to one half instead of sitting across the crease
/// (web/src/ui/layout.js). The fold is the screen's active division region: there only while
/// the device is half folded. UIKit lays the view out again when the regions change, so they
/// are read on every layout, and on every hinge update for good measure.
final class FoldWebView: WKWebView {
    /// The active fold in the view's coordinates (page px), or nil while the screen is flat.
    var onFold: ((CGRect?) -> Void)?
    private(set) var fold: CGRect?
    private var hinge: UIInteraction?
    private var halfOpen = false

    /// How wide the crease is taken to be where the system names none (below).
    private static let crease: CGFloat = 24

    override func layoutSubviews() {
        super.layoutSubviews()
        readFold()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if compiler(>=6.4)
        if #available(iOS 27.1, *), window != nil, hinge == nil {
            let interaction = UIHingeInteraction { [weak self] _, update in
                self?.halfOpen = update.hinge?.status == .partiallyOpen
                self?.readFold()
            }
            addInteraction(interaction)
            hinge = interaction
        }
        #endif
        readFold()
    }

    private func readFold() {
        var next: CGRect?
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            let regions = reservedRegions(kind: .division, options: .includeInactive)
            next = regions.filter(\.isActive).map(\.frame).map { $0.intersection(bounds) }
                .first { !$0.isNull && !$0.isEmpty }
                .map(\.integral)
            // A system that names no division at all, active or not, while the hinge says half
            // open (the iPhone Duo simulator does this): the crease is down the screen's middle.
            if regions.isEmpty, halfOpen { next = middleOfScreen() }
        }
        #endif
        guard next != fold else { return }
        fold = next
        onFold?(next)
    }

    private func middleOfScreen() -> CGRect? {
        guard let screen = window?.windowScene?.screen else { return nil }
        let size = screen.bounds.size
        let centre = convert(CGPoint(x: size.width / 2, y: size.height / 2), from: screen.coordinateSpace)
        guard bounds.insetBy(dx: Self.crease, dy: Self.crease).contains(centre) else { return nil }
        let half = Self.crease / 2
        return size.width > size.height
            ? CGRect(x: centre.x - half, y: 0, width: Self.crease, height: bounds.height).integral
            : CGRect(x: 0, y: centre.y - half, width: bounds.width, height: Self.crease).integral
    }
}
