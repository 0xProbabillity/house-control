import SwiftUI

@main
struct HouseControlApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setActive(phase == .active)
                }
        }
    }
}
