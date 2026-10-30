// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "V19NativeIME",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "V19NativeIME", targets: ["V19NativeIME"])],
    targets: [
        .target(name: "CV19IMECore", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("c++")]),
        .target(name: "V19NativeIME", dependencies: ["CV19IMECore"],
                resources: [.copy("Resources")],
                linkerSettings: [.linkedFramework("CoreML"), .linkedFramework("Foundation")])
    ],
    swiftLanguageVersions: [.v5], cxxLanguageStandard: .cxx17
)
