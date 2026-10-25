import UIKit
import SwiftUI

/// Final user-selected multicolor artwork. Both targets load the same resources;
/// no template tint, gray overlay, or appearance-dependent color replacement.
@MainActor enum ToolArtwork {
    private static var cache: [String: UIImage] = [:]
    private static func asset(_ symbol: String) -> String? {
        switch symbol {
        case "character.bubble.fill": return "language"
        case "doc.on.clipboard.fill", "doc.on.clipboard": return "clipboard"
        case "face.smiling.fill": return "emoji"
        case "keyboard.fill": return "onehand"
        case "paintpalette.fill": return "appearance"
        case "rectangle.3.group.fill", "rectangle.3.group": return "toolbar"
        case "desktopcomputer": return "compatibility"
        case "key.glass": return "keyglass"
        case "key.color": return "keycolor"
        case "candidate.color": return "textcolor"
        case "candidate.size": return "textsize"
        case "slider.horizontal.3": return "settings"
        case "lock.shield": return "privacy"
        case "waveform": return "phonetic"
        case "doc.text": return "license"
        case "house": return "home"
        case "keyboard": return "input"
        case "haptic": return "haptic"
        case "setup": return "setup"
        case "doc.on.doc": return "copy"
        case "plus.bubble": return "phrases"
        case "selection.pin.in.out": return "selection"
        case "trash": return "trash"
        case "arrow.counterclockwise": return "undo"
        case "magnifyingglass": return "search"
        case "plus", "plus.circle": return "add"
        case "checkmark": return "check"
        case "xmark": return "close"
        case "chevron.up", "chevron.left": return "back"
        case "chevron.down": return "expand"
        case "ellipsis": return "more"
        case "arrow.up.left.and.arrow.down.right": return "fullsize"
        case "arrow.left", "arrow.right": return "leftright"
        case "arrow.up.and.down", "key.height": return "height"
        case "shift", "shift.fill", "capslock.fill": return "shift"
        case "delete.left": return "backspace"
        case "arrow.up.right": return "open"
        case "globe": return "globe"
        default: return nil
        }
    }
    static func tint(_ symbol: String) -> UIColor { .systemBlue }
    static func stencil(_ symbol: String, scale: CGFloat = 3) -> UIImage {
        image(symbol: symbol, size: 32, scale: scale).withRenderingMode(.alwaysTemplate)
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
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image; return image
    }
    private static func brandMaterial(_ source: UIImage) -> UIImage {
        if let value = cache["brand.material"] { return value }
        guard let bitmap = source.cgImage else { return source }
        guard let image = BrandMaterial.image(bitmap) else { return source }
        let result = UIImage(cgImage: image,scale: source.scale,orientation: .up)
        cache["brand.material"] = result; return result
    }

    static func image(symbol: String, size: CGFloat = 28, scale: CGFloat? = nil, style: UIUserInterfaceStyle? = nil) -> UIImage {
        let scale = scale ?? UIScreen.main.scale
        let key = "selected:\(symbol):\(size):\(scale)"
        if let value = cache[key] { return value }
        let original: UIImage?
        if let name = asset(symbol), let url = Bundle.main.url(forResource: "icon-" + name, withExtension: "png", subdirectory: "ToolIcons") {
            original = UIImage(contentsOfFile: url.path)
        } else {
            original = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular))
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let value = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            original?.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = value; return value
    }
    static func shift(active: Bool, capsLocked: Bool, ink: UIColor) -> UIImage {
        let source = image(symbol: "shift", size: 28)
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28), format: format).image { renderer in
            renderer.cgContext.saveGState()
            if !capsLocked { renderer.cgContext.clip(to: CGRect(x: 0, y: 0, width: 28, height: 22)) }
            (active ? source : source.withTintColor(ink, renderingMode: .alwaysOriginal)).draw(at: .zero)
            renderer.cgContext.restoreGState()
        }.withRenderingMode(.alwaysOriginal)
    }
}

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
        ink.image = ToolArtwork.image(symbol: value, size: 32)
    }
    override func layoutSubviews() { super.layoutSubviews(); ink.frame = bounds }
}

struct ToolIcon: UIViewRepresentable {
    let symbol: String
    func makeUIView(context: Context) -> ToolIconView { ToolIconView(symbol: symbol) }
    func updateUIView(_ view: ToolIconView, context: Context) { view.setSymbol(symbol) }
}

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
