import Foundation

enum InputResources {
    // One model/resource copy in the embedded keyboard; main-App previews use it read-only.
    static var bundles:[Bundle] {
        #if SWIFT_PACKAGE
        return [Bundle.module,Bundle.main]
        #else
        let main=Bundle.main
        if main.bundleURL.pathExtension == "appex" {return [main]}
        if let keyboard=Bundle(url:main.bundleURL.appendingPathComponent("PlugIns/ClearKeyboardExtension.appex")) {return [keyboard,main]}
        return [main]
        #endif
    }
    static func url(_ name:String,extension suffix:String,directory:String?=nil)->URL? {
        for bundle in bundles {if let url=bundle.url(forResource:name,withExtension:suffix,subdirectory:directory) {return url}}
        return nil
    }
}
