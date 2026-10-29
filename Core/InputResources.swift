import Foundation

enum InputResources {
    // Signed, immutable model and data are packaged once in the containing App.
    static var bundles: [Bundle] {
        #if SWIFT_PACKAGE
        return [Bundle.module, Bundle.main]
        #else
        let main = Bundle.main
        if main.bundleURL.pathExtension == "appex",
           let app=Bundle(url:main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()) {return [main,app]}
        if let keyboard=Bundle(url:main.bundleURL.appendingPathComponent("PlugIns/ClearKeyboardExtension.appex")) {return [main,keyboard]}
        return [main]
        #endif
    }
    static func url(_ name: String, extension suffix: String, directory: String? = nil) -> URL? {
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: suffix, subdirectory: directory) { return url }
        }
        return nil
    }
}
