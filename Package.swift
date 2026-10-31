// swift-tools-version: 5.9
import PackageDescription
let package=Package(name:"ClearCore",platforms:[.iOS("18.0")],
    products:[.library(name:"ClearCore",targets:["ClearCore"])],targets:[
        .target(name:"CV21IMECore",path:"Native/V21NativeIME/Sources/CV21IMECore",publicHeadersPath:"include",linkerSettings:[.linkedLibrary("c++")]),
        .target(name:"V21NativeIME",dependencies:["CV21IMECore"],path:"Native/V21NativeIME/Sources/V21NativeIME",
            resources:[.copy("Resources")],linkerSettings:[.linkedFramework("CoreML")]),
        .target(name:"ClearCore",dependencies:["V21NativeIME"],path:"Core",
            resources:[.copy("Resources/Runtime/V21"),.process("Resources/V21/V21PinyinCompactFP16.mlpackage")],
            linkerSettings:[.linkedFramework("CoreML")])
    ],cxxLanguageStandard:.cxx17)
