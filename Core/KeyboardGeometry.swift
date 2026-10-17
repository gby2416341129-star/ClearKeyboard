import Foundation
import CoreGraphics

public enum KeyboardGeometry {
    public static func contentHeight(total: CGFloat, preferred: CGFloat, reservedBottom: CGFloat) -> CGFloat {
        guard total.isFinite, preferred.isFinite, reservedBottom.isFinite else { return 0 }
        // Some hosts already provide only the extension's content rectangle.
        return max(0, total >= preferred + reservedBottom - 1 ? total - max(0, reservedBottom) : total)
    }
    /// Fit the four rows to the height the host actually gives us, including during resize animations.
    public static func rowHeight(availableHeight: CGFloat, header: CGFloat = 48, preferred: CGFloat = 56) -> CGFloat {
        guard availableHeight.isFinite, header.isFinite, preferred.isFinite else { return 0 }
        return min(max(0, preferred), max(0, availableHeight - header - 8) / 4)
    }
    /// UIKit can lay out a key at zero size while its input view is being attached.
    public static func keyPlate(in bounds: CGRect) -> CGRect {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 0, bounds.height >= 0 else { return .zero }
        let x = min(3, bounds.width / 2), y = min(4, bounds.height / 2)
        return CGRect(x: bounds.minX + x, y: bounds.minY + y,
                      width: max(0, bounds.width - x * 2), height: max(0, bounds.height - y * 2))
    }
}
