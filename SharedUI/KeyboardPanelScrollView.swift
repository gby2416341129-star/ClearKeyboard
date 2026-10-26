import UIKit

@MainActor extension UIScrollView {
    /// The keyboard root provides continuous receiving coverage. Local scroll
    /// view films create rectangular background seams inside that surface.
    func prepareForKeyboardPanel() {
        backgroundColor = .clear; isOpaque = false
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
