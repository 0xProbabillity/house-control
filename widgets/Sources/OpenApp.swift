#if os(iOS)
import AppIntents
import Foundation

// Opening the app from a control (Control Center, the Lock Screen, the Action button) and from
// Shortcuts. This file is part of the app as well as of the widget extension: an intent that
// opens the app has to be known to both, and the system runs it in the app.

/// Where the app opens.
enum AppScreen: String, AppEnum {
    case home, editor, settings

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static let caseDisplayRepresentations: [AppScreen: DisplayRepresentation] = [
        .home: DisplayRepresentation(title: "Home", subtitle: "The home in 3D", image: .init(systemName: "house.fill")),
        .editor: DisplayRepresentation(title: "Floor Plan", subtitle: "The editor", image: .init(systemName: "pencil.and.ruler.fill")),
        .settings: DisplayRepresentation(title: "Settings", subtitle: "Connections, sync, quick actions", image: .init(systemName: "gearshape.fill")),
    ]

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .editor: "pencil.and.ruler.fill"
        case .settings: "gearshape.fill"
        }
    }
}

/// Hands the screen an intent asks for to the app. The intent runs in the app's own process
/// (`openAppWhenRun`), so the app's model takes it from here; one that comes before the model
/// is ready waits in `pending`.
@MainActor
enum OpenAppRouter {
    static var handler: ((AppScreen) -> Void)? {
        didSet {
            guard let handler, let screen = pending else { return }
            pending = nil
            handler(screen)
        }
    }
    static var pending: AppScreen?

    static func open(_ screen: AppScreen) {
        if let handler { handler(screen) } else { pending = screen }
    }
}

@available(iOS 18.0, *)
struct OpenHouseControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Open House Control"
    static let description = IntentDescription("Opens House Control on the home, the floor plan editor or settings.")
    static let openAppWhenRun = true

    @Parameter(title: "Screen", default: .home) var screen: AppScreen

    init() {}
    init(screen: AppScreen) { self.screen = screen }

    static var parameterSummary: some ParameterSummary { Summary("Open House Control on \(\.$screen)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        OpenAppRouter.open(screen)
        return .result()
    }
}
#endif
