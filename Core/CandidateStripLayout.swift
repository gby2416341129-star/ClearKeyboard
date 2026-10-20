import Foundation

/// Exact geometry for a measured prefix, with no estimated positions to move
/// words under a scrolling finger. Offscreen text is measured only as needed.
struct CandidateStripLayout {
    private(set) var frames: [CGRect] = []
    var width: CGFloat { frames.last?.maxX ?? 0 }
    mutating func reset() { frames.removeAll(keepingCapacity: true) }
    mutating func resize(height: CGFloat) {
        guard frames.first?.height != height else { return }
        for index in frames.indices { frames[index].size.height = height }
    }
    @discardableResult
    mutating func extend(count: Int, viewport: CGRect, through index: Int? = nil,
                         measure: (Int) -> CGFloat) -> Int {
        guard count > 0, viewport.width > 0, viewport.width.isFinite else { return 0 }
        let visibleEnd = max(0, viewport.maxX)
        let horizon = visibleEnd + viewport.width * 2
        var measured = 0
        while frames.count < count {
            let requiredIndex = index.map { frames.count <= $0 } ?? false
            if !requiredIndex, width >= horizon { break }
            // Fill the visible viewport, then bound speculative work. A fast
            // scroll will extend the next exact prefix in its normal callback.
            if !requiredIndex, measured >= 16, width >= visibleEnd { break }
            let value = measure(frames.count)
            let cellWidth = value.isFinite ? max(1, value) : max(1, viewport.width)
            frames.append(CGRect(x: width, y: 0, width: cellWidth, height: viewport.height))
            measured += 1
        }
        return measured
    }
    func firstIndex(at x: CGFloat) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxX < x { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
