import SwiftUI
import UIKit

@main struct ClearKeyboardApp: App {
    @StateObject private var preferences = Preferences()
    var body: some Scene {
        WindowGroup {
#if DEBUG && SHELL_NATIVE_HOST
            if ProcessInfo.processInfo.arguments.contains("--shell-native-host") {
                NativeShellHost()
            } else { RootView().environmentObject(preferences).tint(AppPalette.accent) }
#else
            RootView().environmentObject(preferences).tint(AppPalette.accent)
#endif
        }
    }
}

