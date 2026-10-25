import UIKit

/// Keep value geometry only; allocate UIKit attributes for visible rows.
@MainActor final class ClipboardTokenLayout: UICollectionViewLayout {
    var widthForToken: ((Int) -> CGFloat)?
    var tokenWidths: [CGFloat] = [] { didSet { frames = []; invalidateLayout() } }
    private var frames: [CGRect] = []
    private var size = CGSize.zero
    private var preparedWidth: CGFloat = -1
    override func prepare() {
        super.prepare()
        guard let view = collectionView else { return }
        let count = view.numberOfItems(inSection: 0), width = max(1, view.bounds.width)
        guard preparedWidth != width || frames.count != count else { return }
        preparedWidth = width
        var x: CGFloat = 4, y: CGFloat = 4
        frames = (0..<count).map { index in
            let measured = tokenWidths.indices.contains(index) ? tokenWidths[index] : widthForToken?(index) ?? 28
            let w = min(max(1, width - 8), max(28, measured))
            if x + w > width - 4, x > 4 { x = 4; y += 38 }
            let frame = CGRect(x: x, y: y, width: w, height: 34); x += w + 4
            return frame
        }
        size = CGSize(width: width, height: count == 0 ? 0 : y + 38)
    }
    override var collectionViewContentSize: CGSize { size }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { collectionView?.bounds.width != newBounds.width }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxY < rect.minY { low = middle + 1 } else { high = middle }
        }
        var output: [UICollectionViewLayoutAttributes] = [], index = low
        while index < frames.count && frames[index].minY <= rect.maxY {
            if frames[index].intersects(rect), let value = layoutAttributesForItem(at: IndexPath(item: index, section: 0)) { output.append(value) }
            index += 1
        }
        return output
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard frames.indices.contains(indexPath.item) else { return nil }
        let value = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        value.frame = frames[indexPath.item]; return value
    }
}