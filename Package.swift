// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClearCore",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [.library(name: "ClearCore", targets: ["ClearCore"])],
    targets: [
        .target(name: "ClearCore", path: "Core", resources: [.process("Resources")]),
        .testTarget(name: "ClearCoreTests", dependencies: ["ClearCore"], path: "Tests")
    ]
)
