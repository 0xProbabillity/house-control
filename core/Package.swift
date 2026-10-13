// swift-tools-version:5.9
import PackageDescription

// What the macOS and iOS apps share: the Smart Life / Tuya clients, the plan store
// and the Mac ⇄ iPhone sync.
let package = Package(
    name: "HouseCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "HouseCore", targets: ["HouseCore"])
    ],
    targets: [
        .target(name: "HouseCore", path: "Sources/HouseCore"),
        .testTarget(name: "HouseCoreTests", dependencies: ["HouseCore"], path: "Tests/HouseCoreTests"),
    ]
)
