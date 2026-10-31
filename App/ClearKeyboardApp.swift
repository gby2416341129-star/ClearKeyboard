import SwiftUI
import UIKit

@main struct ClearKeyboardApp: App {
    @StateObject private var preferences = Preferences()
    init() { Task.detached(priority:.userInitiated) { _ = try? await V21InputService.shared.prepare() } }
    var body: some Scene {
        WindowGroup { RootView().environmentObject(preferences).tint(AppPalette.accent) }
    }
}

