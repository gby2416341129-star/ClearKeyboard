import UIKit

@MainActor enum ClearBrand {
    private static var cache: [CGFloat: UIImage] = [:]
    static func image(_ size: CGFloat = 24) -> UIImage {
        if let image = cache[size] { return image }
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            UIColor.white.setStroke(); UIColor.white.setFill()
            let arc = UIBezierPath(arcCenter: CGPoint(x: size * 0.49, y: size * 0.5), radius: size * 0.30,
                                   startAngle: .pi * 0.24, endAngle: .pi * 1.76, clockwise: true)
            arc.lineWidth = size * 0.14; arc.lineCapStyle = .round; arc.stroke()
            UIBezierPath(ovalIn: CGRect(x: size * 0.69, y: size * 0.44, width: size * 0.13, height: size * 0.13)).fill()
        }.withRenderingMode(.alwaysTemplate)
        cache[size] = image; return image
    }
}
