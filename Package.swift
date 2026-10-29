// swift-tools-version: 5.9
import PackageDescription
let package=Package(name:"ClearCore",platforms:[.iOS("18.0")],
    products:[.library(name:"ClearCore",targets:["ClearCore"])],targets:[
        .target(name:"CNative",path:"CNative",publicHeadersPath:"include",linkerSettings:[.linkedLibrary("c++")]),
        .target(name:"ClearCore",dependencies:["CNative"],path:"Core",
            resources:[.process("Resources/english.clx"),.copy("Resources/Pinyin"),.copy("Resources/Runtime/V10")],
            linkerSettings:[.linkedFramework("CoreML")])
    ],cxxLanguageStandard:.cxx17)
