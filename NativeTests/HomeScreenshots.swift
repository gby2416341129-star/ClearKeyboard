import XCTest
import SwiftUI
import UIKit
@testable import ClearKeyboard

@MainActor final class HomeScreenshots: XCTestCase {
    func testHomeSafeAreaAndAppearance() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: ClearKeyboard.RootView().environmentObject(ClearKeyboard.Preferences()))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(nanoseconds: 700_000_000)
            window.setNeedsLayout(); window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = style == .dark ? "home-dark" : "home-light"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertGreaterThan(window.safeAreaInsets.top, 0)
        }
    }
}
