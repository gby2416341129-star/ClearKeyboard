import Foundation
import CoreGraphics

public enum KeyboardGeometry {
    public static let headerHeight: CGFloat = 44
    public static let horizontalInset: CGFloat = 4
    public struct Metrics: Equatable {
        public let rowPitch: CGFloat
        public let bottomInset: CGFloat = 8
        public var mainAreaHeight: CGFloat { rowPitch * 4 }
        public var contentHeight: CGFloat { KeyboardGeometry.headerHeight + mainAreaHeight + bottomInset }
        public init(keyHeight: Double = 50) {
            rowPitch = CGFloat(min(58, max(44, keyHeight.isFinite ? keyHeight : 50)) + 6)
        }
    }
    public struct Layout {
        public let header: CGRect
        public let keys: CGRect
        public let sideRail: CGRect
        public let panel: CGRect
        public let rowPitch: CGFloat
        public var unitWidth: CGFloat { keys.width / 10 }
    }
    public static func preferredHeight(keyHeight: Double = 50) -> CGFloat {
        Metrics(keyHeight: keyHeight).contentHeight
    }
    /// Horizontal space belongs to the host. Its window can be wider than the keyboard.
    public static func fittingWidth(primary: CGFloat, container: CGFloat, window: CGFloat) -> CGFloat {
        [primary, container, window].first { $0.isFinite && $0 > 0 } ?? 0
    }
    /// Keep main-area metrics separate from host insets and the one-hand alignment.
    /// The system owns the globe/home-indicator area below the extension; it is not an inset here.
    public static func layout(size: CGSize, metrics: Metrics, hand: HandMode = .full,
                              oneHandFraction: Double = 0.78, leadingInset: CGFloat = 0,
                              trailingInset: CGFloat = 0, fitHeight: Bool = false) -> Layout {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let left = min(width, leadingInset.isFinite ? max(0, leadingInset) : 0)
        let right = min(width - left, trailingInset.isFinite ? max(0, trailingInset) : 0)
        let available = width - left - right
        let fraction = CGFloat(oneHandFraction.isFinite ? min(0.88, max(0.68, oneHandFraction)) : 0.78)
        let keyboardWidth = hand == .full ? available : available * fraction
        let origin = hand == .right ? width - right - keyboardWidth : left
        let height = fitHeight ? contentHeight(total: size.height, preferred: metrics.contentHeight) : metrics.contentHeight
        let pitch = fitHeight ? rowHeight(availableHeight: height, header: headerHeight, preferred: metrics.rowPitch) : metrics.rowPitch
        let inset = min(horizontalInset, keyboardWidth / 2)
        let header = CGRect(x: origin + min(16, keyboardWidth / 2), y: 0, width: max(0, keyboardWidth - 32), height: headerHeight)
        let keys = CGRect(x: origin + inset, y: headerHeight, width: max(0, keyboardWidth - inset * 2), height: max(0, height - headerHeight))
        let rail = CGRect(x: hand == .right ? left + 4 : origin + keyboardWidth + 4, y: headerHeight + 8,
                          width: hand == .full ? 0 : max(0, available - keyboardWidth - 8), height: max(0, pitch * 4 - 16))
        let panel = CGRect(x: origin + min(12, keyboardWidth / 2), y: headerHeight,
                           width: max(0, keyboardWidth - 24), height: max(0, height - headerHeight - 12))
        return Layout(header: header, keys: keys, sideRail: rail, panel: panel, rowPitch: pitch)
    }
    public static func contentHeight(total: CGFloat, preferred: CGFloat) -> CGFloat {
        guard total.isFinite, preferred.isFinite else { return 0 }
        // This is the extension's content, not the system-owned globe/home-indicator area.
        // Never add or subtract a browser's inherited safe-area inset from these rows.
        return max(0, min(total, preferred))
    }
    /// Fit the four rows to the height the host actually gives us, including during resize animations.
    public static func rowHeight(availableHeight: CGFloat, header: CGFloat = KeyboardGeometry.headerHeight, preferred: CGFloat = 56) -> CGFloat {
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
