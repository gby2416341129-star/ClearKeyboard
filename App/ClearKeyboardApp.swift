import SwiftUI
import UIKit

@main struct ClearKeyboardApp: App {
    @StateObject private var preferences = Preferences()
    init() { V21InputService.startPreparing() }
    var body: some Scene {
        WindowGroup { RootView().environmentObject(preferences).tint(AppPalette.accent) }
    }
}

