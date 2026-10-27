// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ClearCore",
    platforms: [.iOS("18.0")],
    products: [.library(name: "ClearCore", targets: ["ClearCore"])],
    targets: [
        .binaryTarget(name: "LlamaRuntime", path: ".build/qwen-runtime/llama.xcframework"),
        .target(name: "CQwen", dependencies: ["LlamaRuntime"], path: "CQwen", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate"), .linkedFramework("Metal"), .linkedFramework("MetalKit")]),
        .target(name: "ClearCore", dependencies: ["CQwen"], path: "Core", resources: [.process("Resources/english.clx"), .copy("Resources/Models"), .copy("Resources/Pinyin"), .process("Resources/GPU/default.metallib")])
    ], cxxLanguageStandard: .cxx17
)
