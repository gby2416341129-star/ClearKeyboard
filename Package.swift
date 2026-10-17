// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClearCore",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [.library(name: "ClearCore", targets: ["ClearCore"])],
    dependencies: [.package(url: "https://github.com/ghostflyby/librime-xcframework.git", exact: "1.17.0-pack.10.0.0")],
    targets: [
        .target(name: "CRime", dependencies: [.product(name: "RimeStatic", package: "librime-xcframework")], path: "CRime", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("c++")]),
        .target(name: "ClearCore", dependencies: ["CRime"], path: "Core", resources: [.process("Resources/pinyin.clx"), .process("Resources/english.clx"), .process("Resources/pinyin-corrections.clx"), .process("Resources/associations.clx"), .copy("Resources/Rime")]),
        .testTarget(name: "ClearCoreTests", dependencies: ["ClearCore"], path: "Tests")
    ], cxxLanguageStandard: .cxx17
)
