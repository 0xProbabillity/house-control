import AppKit
import HouseCore
import HouseSmartLife

MainActor.assumeIsolated {
    // `--selftest-mapper`, `--selftest-infrared`, `--selftest-transport` and
    // `--diagnose <id>…` print their result and exit without starting the app.
    SelfTest.runIfRequested()

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only: no Dock icon (HOUSE_DOCK=1 shows one, handy for UI automation).
    app.setActivationPolicy(ProcessInfo.processInfo.environment["HOUSE_DOCK"] != nil ? .regular : .accessory)
    app.run()
}
