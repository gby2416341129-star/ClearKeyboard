// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "V21NativeIME", platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "V21NativeIME", targets: ["V21NativeIME"])],
    targets: [.target(name: "CV21IMECore", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("c++")]),
              .target(name: "V21NativeIME", dependencies: ["CV21IMECore"], resources: [.copy("Resources")],
                      linkerSettings: [.linkedFramework("CoreML"), .linkedFramework("Foundation"), .linkedFramework("CryptoKit")])],
    swiftLanguageVersions: [.v5], cxxLanguageStandard: .cxx17)
