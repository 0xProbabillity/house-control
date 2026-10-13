// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HouseControl",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "HouseControl", path: "Sources/HouseControl")
    ]
)
