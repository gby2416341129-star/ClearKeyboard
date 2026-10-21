import UIKit

/// Cached multicolor objects, with no enclosing badge.
@MainActor enum ToolArtwork {
    private static var cache: [String: UIImage] = [:]
    static func brand(size: CGFloat = 28) -> UIImage { image(symbol: "clear.prism", size: size) }
    static func image(symbol: String, size: CGFloat = 28, scale: CGFloat = UIScreen.main.scale) -> UIImage {
        let key = "\(symbol):\(size):\(scale)"
        if let image = cache[key] { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { renderer in
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
            case "clear.prism":
                // A folded ribbon with an open center. Shared with the app icon.
                let outer = UIBezierPath(roundedRect: CGRect(x: 3, y: 3, width: 26, height: 26), cornerRadius: 8)
                let inner = UIBezierPath(roundedRect: CGRect(x: 10, y: 10, width: 12, height: 12), cornerRadius: 3)
                outer.append(inner); outer.usesEvenOddFillRule = true
                fill(outer, 0x64E6DB, 0x3D64DF)
                let fold = UIBezierPath(); fold.move(to: CGPoint(x: 16, y: 3)); fold.addLine(to: CGPoint(x: 29, y: 16))
                fold.addLine(to: CGPoint(x: 22, y: 22)); fold.addLine(to: CGPoint(x: 16, y: 10)); fold.close()
                fill(fold, 0xA6F5E9, 0x37A8DB)
                let edge = UIBezierPath(); edge.move(to: CGPoint(x: 3, y: 16)); edge.addLine(to: CGPoint(x: 10, y: 10))
                edge.addLine(to: CGPoint(x: 16, y: 22)); edge.addLine(to: CGPoint(x: 16, y: 29)); edge.close()
                fill(edge, 0x4086E0, 0x765CD7)
            case "doc.on.clipboard.fill":
                fill(rect(3, 4, 26, 25, 6), 0x69BEFC, 0x2D6FDD)
                fill(rect(7, 7, 18, 20, 3), 0xF6FCFF, 0xC4E3FF)
                fill(rect(10, 3, 12, 6, 2.5), 0xB4F1EE, 0x57BCC7)
                for y: CGFloat in [13, 18, 23] { line([CGPoint(x: 11, y: y), CGPoint(x: 21, y: y)], color(0x5689BD), 1.6) }
            case "face.smiling.fill":
                // A friendly rounded face tile, with balanced eyes and a filled smile.
                fill(rect(3, 3, 26, 26, 9), 0xFFE69B, 0xF9B84D)
                color(0x794F2D).setFill()
                UIBezierPath(roundedRect: CGRect(x: 10, y: 11, width: 2.5, height: 3.2), cornerRadius: 1.25).fill()
                UIBezierPath(roundedRect: CGRect(x: 19.5, y: 11, width: 2.5, height: 3.2), cornerRadius: 1.25).fill()
                let smile = UIBezierPath(); smile.move(to: CGPoint(x: 9, y: 18))
                smile.addQuadCurve(to: CGPoint(x: 23, y: 18), controlPoint: CGPoint(x: 16, y: 22))
                smile.addCurve(to: CGPoint(x: 9, y: 18), controlPoint1: CGPoint(x: 22, y: 27), controlPoint2: CGPoint(x: 10, y: 27)); smile.close()
                fill(smile, 0x8B5931, 0xAC6D36)
                let teeth = UIBezierPath(); teeth.move(to: CGPoint(x: 10.5, y: 19)); teeth.addQuadCurve(to: CGPoint(x: 21.5, y: 19), controlPoint: CGPoint(x: 16, y: 22))
                teeth.lineWidth = 1.3; teeth.lineCapStyle = .round; color(0xFFF5DD).setStroke(); teeth.stroke()
            case "keyboard.fill":
                fill(rect(3, 3, 26, 26, 6), 0x93CAFA, 0x5272C6)
                fill(rect(6, 8, 20, 17, 3), 0xF4F8FF, 0xC9DBF5)
                for row in 0..<2 { for column in 0..<5 { fill(rect(8 + CGFloat(column) * 3.4, 11 + CGFloat(row) * 4.1, 2.2, 2.5, 0.7), 0x91B6EB, 0x668FC9) } }
                fill(rect(11, 20, 10, 2.3, 0.8), 0x91B6EB, 0x668FC9)
            case "character.bubble.fill":
                fill(rect(2, 3, 19, 23, 4), 0x80D4FF, 0x3683D8)
                fill(rect(12, 10, 18, 21, 4), 0xC3A6FA, 0x7956D1)
                ("文" as NSString).draw(at: CGPoint(x: 5, y: 7), withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.white])
                ("A" as NSString).draw(at: CGPoint(x: 17, y: 13), withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.white])
            case "paintpalette.fill", "slider.horizontal.3":
                fill(rect(3, 3, 26, 26, 7), 0xF3F5FA, 0xAEBED4)
                let dots: [(CGFloat, CGFloat, UInt32, UInt32)] = [(8, 8, 0x5DCCF4, 0x1685D8), (17, 8, 0xFFA8D0, 0xDA4D97), (8, 17, 0xFFDD86, 0xEE9E32)]
                for (x, y, top, bottom) in dots { fill(UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 7, height: 7)), top, bottom) }
                c.saveGState(); c.translateBy(x: 23, y: 20); c.rotate(by: .pi / 5)
                fill(rect(-2, -9, 4, 16, 1.5), 0x84B9F7, 0x355A9D)
                fill(rect(-2.5, 3, 5, 5, 2), 0xE6C49A, 0x9A674D); c.restoreGState()
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
