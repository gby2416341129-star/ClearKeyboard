import UIKit

/// Cached multicolor objects, with no enclosing badge.
@MainActor enum ToolArtwork {
    private static var cache: [String: UIImage] = [:]
    static func brand(size: CGFloat = 28) -> UIImage { image(symbol: "clear.drop", size: size) }
    static func image(symbol: String, size: CGFloat = 28) -> UIImage {
        let key = "\(symbol):\(size)"
        if let image = cache[key] { return image }
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { renderer in
            let c = renderer.cgContext; c.scaleBy(x: size / 32, y: size / 32)
            func color(_ hex: UInt32) -> UIColor { UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
            func fill(_ path: UIBezierPath, _ top: UInt32, _ bottom: UInt32) {
                c.saveGState(); path.addClip()
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(top).cgColor, color(bottom).cgColor] as CFArray, locations: [0, 1]) {
                    c.drawLinearGradient(gradient, start: CGPoint(x: 4, y: 1), end: CGPoint(x: 27, y: 32), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
                c.restoreGState()
            }
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat = 3) -> UIBezierPath { UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius) }
            func line(_ points: [CGPoint], _ ink: UIColor, _ width: CGFloat) {
                guard let first = points.first else { return }
                let path = UIBezierPath(); path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }
                path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; ink.setStroke(); path.stroke()
            }
            switch symbol {
            case "clear.drop":
                let drop = UIBezierPath(); drop.move(to: CGPoint(x: 16, y: 1))
                drop.addCurve(to: CGPoint(x: 29, y: 20), controlPoint1: CGPoint(x: 22, y: 9), controlPoint2: CGPoint(x: 29, y: 13))
                drop.addCurve(to: CGPoint(x: 3, y: 20), controlPoint1: CGPoint(x: 29, y: 35), controlPoint2: CGPoint(x: 3, y: 35))
                drop.addCurve(to: CGPoint(x: 16, y: 1), controlPoint1: CGPoint(x: 3, y: 13), controlPoint2: CGPoint(x: 10, y: 9)); drop.close()
                fill(drop, 0x69E8E3, 0x1767CE)
                c.saveGState(); drop.addClip()
                fill(UIBezierPath(ovalIn: CGRect(x: -6, y: 11, width: 31, height: 24)), 0xB9F8EE, 0x31BDB4)
                c.restoreGState()
                line([CGPoint(x: 11, y: 14), CGPoint(x: 8, y: 20)], UIColor.white.withAlphaComponent(0.8), 2.1)
            case "doc.on.clipboard.fill":
                fill(rect(5, 4, 20, 25, 4), 0x58B9FA, 0x2662D5)
                fill(rect(9, 7, 19, 24, 3), 0xF6FCFF, 0xBADEFF)
                fill(rect(10, 2, 10, 6, 2), 0x92E3EA, 0x258CAB)
                for y: CGFloat in [13, 18, 23] { line([CGPoint(x: 13, y: y), CGPoint(x: 23, y: y)], color(0x528FC8), 1.8) }
            case "face.smiling.fill":
                fill(UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 28, height: 28)), 0xFFE788, 0xF4A325)
                color(0x70401E).setFill()
                UIBezierPath(ovalIn: CGRect(x: 9, y: 11, width: 3, height: 4)).fill()
                UIBezierPath(ovalIn: CGRect(x: 20, y: 11, width: 3, height: 4)).fill()
                let smile = UIBezierPath(); smile.move(to: CGPoint(x: 9, y: 20)); smile.addQuadCurve(to: CGPoint(x: 23, y: 20), controlPoint: CGPoint(x: 16, y: 30))
                smile.lineWidth = 2.2; smile.lineCapStyle = .round; color(0xAC561E).setStroke(); smile.stroke()
            case "keyboard.fill":
                fill(rect(1, 7, 30, 21, 5), 0x86BEE8, 0x4264A8)
                fill(rect(3, 9, 26, 15, 3), 0xEDF5FC, 0xA4C4DD)
                for row in 0..<2 { for column in 0..<6 { fill(rect(5 + CGFloat(column) * 3.8, 11 + CGFloat(row) * 4, 2.7, 2.7, 0.8), 0xFFFFFF, 0x6C98C3) } }
                fill(rect(10, 20, 12, 2.5, 0.8), 0x6CDAED, 0x2D92C7)
            case "character.bubble.fill":
                fill(rect(2, 3, 19, 23, 4), 0x80D4FF, 0x3683D8)
                fill(rect(12, 10, 18, 21, 4), 0xC3A6FA, 0x7956D1)
                ("文" as NSString).draw(at: CGPoint(x: 5, y: 7), withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.white])
                ("A" as NSString).draw(at: CGPoint(x: 17, y: 13), withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.white])
            case "paintpalette.fill", "slider.horizontal.3":
                fill(rect(3, 4, 24, 24, 7), 0xF3F5FA, 0xAEBED4)
                let dots: [(CGFloat, CGFloat, UInt32, UInt32)] = [(8, 8, 0x5DCCF4, 0x1685D8), (17, 8, 0xFFA8D0, 0xDA4D97), (8, 17, 0xFFDD86, 0xEE9E32)]
                for (x, y, top, bottom) in dots { fill(UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 7, height: 7)), top, bottom) }
                c.saveGState(); c.translateBy(x: 22, y: 21); c.rotate(by: .pi / 5)
                fill(rect(-2, -9, 4, 16, 1.5), 0x84B9F7, 0x355A9D)
                fill(rect(-3, 4, 6, 7, 2), 0xE6C49A, 0x9A674D); c.restoreGState()
            case "rectangle.3.group.fill":
                let tiles: [(CGFloat, CGFloat, UInt32, UInt32)] = [(3, 3, 0x8EDDF7, 0x2785DC), (18, 3, 0xC9B2FA, 0x8860D9), (3, 18, 0x81E5D3, 0x28AB93), (18, 18, 0xFFD78E, 0xF29442)]
                for (x, y, top, bottom) in tiles { fill(rect(x, y, 11, 11, 3), top, bottom) }
            default:
                if let icon = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 23, weight: .medium)) {
                    icon.withTintColor(color(0x4C96CB), renderingMode: .alwaysOriginal).draw(in: CGRect(x: 4, y: 4, width: 24, height: 24))
                }
            }
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image; return image
    }
}
