// swift-tools-version: 5.9
import PackageDescription
let package=Package(name:"ClearCore",platforms:[.iOS("18.0")],
    products:[.library(name:"ClearCore",targets:["ClearCore"])],targets:[
        .target(name:"CV19IMECore",path:"Native/V19NativeIME/Sources/CV19IMECore",publicHeadersPath:"include",linkerSettings:[.linkedLibrary("c++")]),
        .target(name:"V19NativeIME",dependencies:["CV19IMECore"],path:"Native/V19NativeIME/Sources/V19NativeIME",
            resources:[.copy("Resources")],linkerSettings:[.linkedFramework("CoreML")]),
        .target(name:"ClearCore",dependencies:["V19NativeIME"],path:"Core",
            resources:[.copy("Resources/Runtime/V19"),.process("Resources/V19/V19FullPinyinFP16.mlpackage")],
            linkerSettings:[.linkedFramework("CoreML")])
    ],cxxLanguageStandard:.cxx17)
