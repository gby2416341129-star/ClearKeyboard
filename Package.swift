// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QwenANERuntime",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "QwenANERuntime", targets: ["QwenANERuntime"])],
    targets: [.target(name: "QwenANERuntime")]
)
