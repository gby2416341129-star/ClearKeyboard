import UIKit

@MainActor extension UIScrollView {
    /// Remote keyboard hosts may reject contacts on entirely clear pixels before
    /// UIKit sees them. Paint the complete viewport, not just its controls.
    func prepareForKeyboardPanel() {
        backgroundColor = UIColor(white: 0.5, alpha: 0.01); isOpaque = false
        delaysContentTouches = false; canCancelContentTouches = true
        alwaysBounceVertical = true; alwaysBounceHorizontal = false
        showsVerticalScrollIndicator = false; scrollsToTop = false
        contentInsetAdjustmentBehavior = .never
    }
}

@MainActor final class KeyboardPanelScrollView: UIScrollView {
    init() { super.init(frame: .zero); prepareForKeyboardPanel() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func touchesShouldCancel(in view: UIView) -> Bool {
        // A vertical menu pan may cancel an emoji/tool button. A slider keeps
        // its own horizontal adjustment gesture; gaps still belong to the pan.
        !(view is UISlider)
    }
}
