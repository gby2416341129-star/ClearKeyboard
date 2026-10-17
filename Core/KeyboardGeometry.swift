import Foundation
import CoreGraphics

public enum KeyboardGeometry {
    public static let headerHeight: CGFloat = 44
    public static let horizontalInset: CGFloat = 4
    public static func preferredHeight(keyHeight: Double = 50) -> CGFloat {
        headerHeight + CGFloat(keyHeight + 6) * 4 + 8
    }
    public static func contentHeight(total: CGFloat, preferred: CGFloat) -> CGFloat {
        guard total.isFinite, preferred.isFinite else { return 0 }
        // This is the extension's content, not the system-owned globe/home-indicator area.
        // Never add or subtract a browser's inherited safe-area inset from these rows.
        return max(0, min(total, preferred))
    }
    /// Fit the four rows to the height the host actually gives us, including during resize animations.
    public static func rowHeight(availableHeight: CGFloat, header: CGFloat = 48, preferred: CGFloat = 56) -> CGFloat {
        guard availableHeight.isFinite, header.isFinite, preferred.isFinite else { return 0 }
        return min(max(0, preferred), max(0, availableHeight - header - 8) / 4)
    }
    /// UIKit can lay out a key at zero size while its input view is being attached.
    public static func keyPlate(in bounds: CGRect, action: KeyAction? = nil, units: Double = 1) -> CGRect {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 0, bounds.height >= 0 else { return .zero }
        var face = bounds
        if units == 1.5, let action {
            let trim = bounds.width / 1.5 * 0.2
            switch action {
            case .shift, .page:
                face.size.width -= trim
            case .delete:
                face.origin.x += trim; face.size.width -= trim
            default: break
            }
        }
        let x = min(3, face.width / 2), y = min(5.5, face.height / 2)
        return CGRect(x: face.minX + x, y: face.minY + y,
                      width: max(0, face.width - x * 2), height: max(0, face.height - y * 2))
    }
}
