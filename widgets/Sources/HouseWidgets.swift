import SwiftUI
import WidgetKit

/// Every widget and control House Control offers, on the iPhone and the Mac.
@main
struct HouseWidgets: WidgetBundle {
    var body: some Widget {
        HomeWidget()
        ScenesWidget()
        LightWidget()
        RoomWidget()
        ClimateWidget()
        #if os(iOS)
        StatusWidget()
        #endif
        controls
    }

    @WidgetBundleBuilder
    private var controls: some Widget {
        if #available(iOS 18.0, macOS 26.0, *) {
            AllLightsControl()
            LightControl()
            SceneControl()
            ClimateControl()
        }
    }
}
