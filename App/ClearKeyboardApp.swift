import SwiftUI
import UIKit

@main struct ClearKeyboardApp: App {
    @StateObject private var preferences = Preferences()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(preferences).tint(Color(preferences.settings.accentInkColor)) }
    }
}

