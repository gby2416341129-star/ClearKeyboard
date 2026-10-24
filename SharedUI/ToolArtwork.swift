import UIKit
import SwiftUI

/// The symbol itself is the glass object. No enclosing badge or common disk.
@MainActor enum ToolArtwork {
    private static var cache: [String: UIImage] = [:]
    private static func descriptor(_ symbol: String) -> (String,CGFloat) {
        switch symbol {
        case "character.bubble.fill": return ("character.bubble.fill",0.65)
        case "doc.on.clipboard.fill", "doc.on.clipboard": return ("list.clipboard.fill",0.57)
        case "face.smiling.fill": return ("face.smiling.fill",0.105)
        case "keyboard.fill": return ("hand.point.up.left.fill",0.62)
        case "paintpalette.fill": return ("paintpalette.fill",0.80)
        case "rectangle.3.group.fill", "rectangle.3.group": return ("square.grid.2x2.fill",0.68)
        case "desktopcomputer": return ("desktopcomputer",0.56)
        case "key.glass": return ("keyboard.fill",0.60)
        case "key.color": return ("square.on.square.fill",0.70)
        case "candidate.color": return ("character",0.77)
        case "candidate.size": return ("textformat.size",0.63)
        case "clear.mark": return ("water.waves",0.60)
        default: return (symbol,0.64)
        }
    }
    static func tint(_ symbol: String) -> UIColor {
        UIColor(hue: descriptor(symbol).1,saturation: 0.52,brightness: 1,alpha: 1)
    }
    private static func visibleGlyph(_ image: UIImage,scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false; format.preferredRange = .standard
        let raster = UIGraphicsImageRenderer(size: image.size,format: format).image { _ in
            image.draw(in: CGRect(origin: .zero,size: image.size))
        }
        guard let source = raster.cgImage else { return image }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0,count: width*height*4)
        return pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return image }
            context.draw(source,in: CGRect(x: 0,y: 0,width: CGFloat(width),height: CGFloat(height)))
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height { for x in 0..<width where raw[(y*width+x)*4+3] > 24 {
                minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x); maxY = max(maxY,y)
            } }
            guard maxX >= minX, maxY >= minY,
                  let bitmap = context.makeImage()?.cropping(to: CGRect(x: CGFloat(minX),y: CGFloat(minY),width: CGFloat(maxX-minX+1),height: CGFloat(maxY-minY+1))) else { return image }
            return UIImage(cgImage: bitmap,scale: scale,orientation: .up)
        }
    }
    static func stencil(_ symbol: String,scale: CGFloat = 3) -> UIImage {
        let key = "mask:\(symbol):\(scale)"
        if let image = cache[key] { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32,height: 32),format: format).image { _ in
            let config = UIImage.SymbolConfiguration(pointSize: 26,weight: .semibold)
            guard let original = UIImage(systemName: descriptor(symbol).0,withConfiguration: config)?.withTintColor(.white,renderingMode: .alwaysOriginal) else { return }
            let icon = visibleGlyph(original,scale: scale)
            let side: CGFloat = symbol == "candidate.color" ? 22 : 26
            let ratio = min(side/icon.size.width,side/icon.size.height)
            let width = icon.size.width*ratio, height = icon.size.height*ratio
            let y: CGFloat = symbol == "candidate.color" ? 13.5 : 16
            icon.draw(in: CGRect(x: 16-width/2,y: y-height/2,width: width,height: height))
            if symbol == "candidate.color" {
                UIColor.white.setFill(); UIBezierPath(roundedRect: CGRect(x: 5,y: 28,width: 22,height: 2),cornerRadius: 1).fill()
            }
        }
        cache[key] = image; return image
    }
    static func brand(size: CGFloat = 28) -> UIImage {
        let key = "brand:\(size)"
        if let image = cache[key] { return image }
        guard let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
              let data = try? Data(contentsOf: url), let source = UIImage(data: data) else {
            return image(symbol: "water.waves", size: size)
        }
        let material = brandMaterial(source)
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size),format: format).image { _ in
            material.draw(in: CGRect(x: 0,y: 0,width: size,height: size))
        }
        cache[key] = image; return image
    }
    private static func brandMaterial(_ source: UIImage) -> UIImage {
        if let value = cache["brand.material"] { return value }
        guard let bitmap = source.cgImage else { return source }
        let width = bitmap.width, height = bitmap.height
        var pixels = [UInt8](repeating: 0,count: width*height*4)
        let result: UIImage = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return source }
            context.draw(bitmap,in: CGRect(x: 0,y: 0,width: CGFloat(width),height: CGFloat(height)))
            for offset in stride(from: 0,to: raw.count,by: 4) {
                let alpha = Double(raw[offset+3])/255
                guard alpha > 0 else { continue }
                let red = Double(raw[offset])/255/alpha, green = Double(raw[offset+1])/255/alpha, blue = Double(raw[offset+2])/255/alpha
                let luminance = red*0.2126 + green*0.7152 + blue*0.0722
                // Preserve the selected mark's highlights instead of fading
                // its whole surface equally into a grey silhouette.
                let opacity = alpha*(0.25 + 0.63*pow(luminance,5))
                for (channel,value) in [red,green,blue].enumerated() {
                    let color = min(1,max(0,luminance+(value-luminance)*1.42))
                    raw[offset+channel] = UInt8((color*opacity*255).rounded())
                }
                raw[offset+3] = UInt8((opacity*255).rounded())
            }
            guard let image = context.makeImage() else { return source }
            return UIImage(cgImage: image,scale: source.scale,orientation: .up)
        }
        cache["brand.material"] = result; return result
    }
    static func image(symbol: String, size: CGFloat = 28, scale: CGFloat? = nil) -> UIImage {
        let scale = scale ?? UIScreen.main.scale
        let key = "\(symbol):\(size):\(scale)"
        if let image = cache[key] { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let mask = stencil(symbol,scale: scale)
        let value = UIGraphicsImageRenderer(size: CGSize(width: size,height: size),format: format).image { renderer in
            let c = renderer.cgContext; c.scaleBy(x: size/32,y: size/32)
            guard let bitmap = mask.cgImage else { return }
            c.saveGState(); c.translateBy(x: 0,y: 32); c.scaleBy(x: 1,y: -1)
            c.clip(to: CGRect(x: 0,y: 0,width: 32,height: 32),mask: bitmap)
            // A single translucent color keeps the whole symbol equally bright.
            // Shape and depth come from live clear glass, not a painted dark band.
            c.setFillColor(tint(symbol).withAlphaComponent(0.82).cgColor)
            c.fill(CGRect(x: 0,y: 0,width: 32,height: 32))
            c.restoreGState()
        }
        cache[key] = value; return value
    }
}

/// Live system material is clipped to the functional shape itself. The small
/// colored face preserves legibility; no photographed highlights or badge surround it.
@MainActor final class ToolIconView: UIView {
    private let lens = UIVisualEffectView(effect: nil)
    private let shape = UIImageView()
    private let ink = UIImageView()
    private var symbol = ""
    init(symbol: String) {
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear
        isUserInteractionEnabled = false; isAccessibilityElement = false
        shape.contentMode = .scaleAspectFit; ink.contentMode = .scaleAspectFit
        addSubview(lens); addSubview(ink); lens.mask = shape
        setSymbol(symbol)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func setSymbol(_ value: String) {
        guard symbol != value else { return }; symbol = value
        shape.image = ToolArtwork.stencil(value)
        configureMaterial()
    }
    private func configureMaterial() {
        if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
            ink.image = ToolArtwork.image(symbol: symbol,size: 32)
            let effect = UIGlassEffect(style: .clear)
            effect.tintColor = nil
            lens.effect = effect; lens.isHidden = false; ink.alpha = 1
        } else {
            lens.effect = nil; lens.isHidden = true
            ink.image = ToolArtwork.stencil(symbol).withTintColor(ToolArtwork.tint(symbol),renderingMode: .alwaysOriginal)
            ink.alpha = 1
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews(); lens.frame = bounds; shape.frame = lens.bounds; ink.frame = bounds
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection); configureMaterial()
    }
}

struct ToolIcon: UIViewRepresentable {
    let symbol: String
    func makeUIView(context: Context) -> ToolIconView { ToolIconView(symbol: symbol) }
    func updateUIView(_ view: ToolIconView,context: Context) { view.setSymbol(symbol) }
}

/// Compact rectangular controls, with separate readable artwork and thin clear glass.
@MainActor final class ToolTileButton: UIButton {
    private let lens = LiquidGlassView(radius: 16, keycap: true, clear: true)
    private let artwork: ToolIconView
    private let caption = UILabel()
    init(title: String, symbol: String, action: @escaping () -> Void) {
        artwork = ToolIconView(symbol: symbol)
        super.init(frame: .zero)
        addSubview(lens); addSubview(artwork); addSubview(caption)
        caption.text = title; caption.textColor = .label; caption.font = .systemFont(ofSize: 12,weight: .medium)
        caption.textAlignment = .center; caption.adjustsFontSizeToFitWidth = true; caption.minimumScaleFactor = 0.9
        for view in [artwork,caption] { view.isUserInteractionEnabled = false }
        isAccessibilityElement = true; accessibilityLabel = title
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        lens.configure(tint: nil,strength: 0.25,fallback: .secondarySystemBackground)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        lens.frame = bounds
        artwork.frame = CGRect(x: bounds.midX-14,y: 7,width: 28,height: 28)
        caption.frame = CGRect(x: 5,y: 40,width: max(0,bounds.width-10),height: 16)
    }
    override var isHighlighted: Bool {
        didSet { lens.alpha = isHighlighted ? 0.72 : 1 }
    }
}
