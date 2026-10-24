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
    private static func resource(_ symbol: String) -> String? {
        switch symbol {
        case "character.bubble.fill": return "language"
        case "doc.on.clipboard.fill", "doc.on.clipboard": return "clipboard"
        case "face.smiling.fill": return "emoji"
        case "keyboard.fill": return "single-hand"
        case "paintpalette.fill": return "appearance"
        case "rectangle.3.group.fill", "rectangle.3.group": return "toolbar"
        case "desktopcomputer": return "compatibility"
        case "key.glass", "keyboard": return "key-glass"
        case "key.color": return "key-color"
        case "candidate.color": return "text-color"
        case "candidate.size": return "text-size"
        case "slider.horizontal.3": return "settings"
        case "lock.shield": return "privacy"
        case "waveform": return "phonetic"
        case "doc.text": return "license"
        default: return nil
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
        guard let image = BrandMaterial.image(bitmap) else { return source }
        let result = UIImage(cgImage: image,scale: source.scale,orientation: .up)
        cache["brand.material"] = result; return result
    }
    static func image(symbol: String, size: CGFloat = 28, scale: CGFloat? = nil) -> UIImage {
        let scale = scale ?? UIScreen.main.scale
        let key = "\(symbol):\(size):\(scale)"
        if let image = cache[key] { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        if let name = resource(symbol),
           let url = Bundle.main.url(forResource: "tool-" + name,withExtension: "png"),
           let source = UIImage(contentsOfFile: url.path) {
            let icon = visibleGlyph(source,scale: scale)
            let ratio = min(size*0.8125/icon.size.width,size*0.8125/icon.size.height)
            let width = icon.size.width*ratio, height = icon.size.height*ratio
            let value = UIGraphicsImageRenderer(size: CGSize(width: size,height: size),format: format).image { _ in
                // Retain generated partial alpha and shallow glass volume.
                // A quiet overall opacity also softens the fine specular rim.
                icon.draw(in: CGRect(x: (size-width)/2,y: (size-height)/2,width: width,height: height),blendMode: .normal,alpha: 0.86)
            }.withRenderingMode(.alwaysOriginal)
            cache[key] = value; return value
        }
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

/// One shared transparent artwork path for live icons, cached images and drag
/// previews. Do not put another glass lens over the artwork's own quiet rim.
@MainActor final class ToolIconView: UIView {
    private let ink = UIImageView()
    private var symbol = ""
    init(symbol: String) {
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear
        isUserInteractionEnabled = false; isAccessibilityElement = false
        ink.contentMode = .scaleAspectFit; addSubview(ink); setSymbol(symbol)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func setSymbol(_ value: String) {
        guard symbol != value else { return }; symbol = value
        ink.image = ToolArtwork.image(symbol: value,size: 32)
    }
    override func layoutSubviews() { super.layoutSubviews(); ink.frame = bounds }
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
