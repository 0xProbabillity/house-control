// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SharedServerSync", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SharedServerSync", targets: ["SharedServerSync"])],
    dependencies: [.package(path: "../core")],
    targets: [
        .target(name: "SharedServerSync", dependencies: [.product(name: "HouseCore", package: "core")], path: "Sources",
                exclude: ["AppModel.swift", "ConnectionViews.swift", "DevicesView.swift", "EditorScreen.swift", "Haptics.swift", "HomeWeb.swift", "HouseControlApp.swift", "NewHomeView.swift", "PairingView.swift", "QuickActions.swift", "RootView.swift", "ServerSyncView.swift", "SettingsView.swift", "SmartLifeView.swift", "Theme.swift", "WelcomeView.swift"], sources: ["ServerSync.swift"]),
        .testTarget(name: "SharedServerSyncTests", dependencies: ["SharedServerSync", .product(name: "HouseCore", package: "core")], path: "Tests")
    ])
