import SwiftUI
import UIKit

/// Prefer the screen's native refresh rate during UI updates. A passive link
/// does not keep rendering an idle page or publish SwiftUI state every frame.
struct AppRefreshPreference: UIViewRepresentable {
    func makeUIView(context: Context) -> RefreshAnchor { RefreshAnchor() }
    func updateUIView(_ view: RefreshAnchor, context: Context) {}
    final class RefreshAnchor: UIView {
        private var updateLink: UIUpdateLink?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateLink?.isEnabled = false; updateLink = nil
            guard let window else { return }
            let maximum = Float(window.screen.maximumFramesPerSecond)
            let link = UIUpdateLink(view: self)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
            link.requiresContinuousUpdates = false
            link.isEnabled = true; updateLink = link
        }
    }
}
