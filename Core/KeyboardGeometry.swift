import Foundation
import CoreGraphics

public enum KeyboardGeometry {
    /// UIKit can lay out a key at zero size while its input view is being attached.
    public static func keyPlate(in bounds: CGRect) -> CGRect {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 0, bounds.height >= 0 else { return .zero }
        let x = min(3, bounds.width / 2), y = min(4, bounds.height / 2)
        return CGRect(x: bounds.minX + x, y: bounds.minY + y,
                      width: max(0, bounds.width - x * 2), height: max(0, bounds.height - y * 2))
    }
}
