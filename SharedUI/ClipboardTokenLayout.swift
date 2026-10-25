import UIKit

/// Flow layout distributes leftover row width between items. Selection needs
/// compact, predictable gaps, including the last row and hit testing in gaps.
@MainActor final class ClipboardTokenLayout: UICollectionViewLayout {
    var widthForToken: ((Int) -> CGFloat)?
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var size = CGSize.zero
    override func prepare() {
        super.prepare()
        guard let view = collectionView else { return }
        let width = max(1, view.bounds.width), gap: CGFloat = 4, height: CGFloat = 34
        var x: CGFloat = 4, y: CGFloat = 4
        attributes = (0..<view.numberOfItems(inSection: 0)).map { index in
            let w = min(width - 8, max(28, widthForToken?(index) ?? 28))
            if x + w > width - 4, x > 4 { x = 4; y += height + gap }
            let item = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            item.frame = CGRect(x: x, y: y, width: w, height: height); x += w + gap
            return item
        }
        size = CGSize(width: width, height: y + height + 4)
    }
    override var collectionViewContentSize: CGSize { size }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { collectionView?.bounds.width != newBounds.width }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }
}
