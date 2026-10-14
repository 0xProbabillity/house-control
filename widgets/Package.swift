// swift-tools-version:5.9
import PackageDescription

// Draws the widgets as still images, outside WidgetKit: `swift run render-widgets`
// (README images, the promo video). The widget extensions themselves are built by the
// iPhone app's Xcode project and by scripts/build-app.sh for the Mac.
let package = Package(
    name: "HouseWidgets",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../core")],
    targets: [
        .target(name: "WidgetViews", dependencies: [.product(name: "HouseCore", package: "core")],
                path: "Sources", exclude: ["HouseWidgets.swift"]),
        .executableTarget(name: "render-widgets", dependencies: ["WidgetViews", .product(name: "HouseCore", package: "core")],
                          path: "Render"),
    ]
)
