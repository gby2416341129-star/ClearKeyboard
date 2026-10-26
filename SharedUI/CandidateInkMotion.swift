import UIKit
import Accelerate

/// Transparent glyph layers only. The blur progression follows Pow's blur +
/// opacity transition principle, without filtering the keyboard's glass backdrop.
/// Reference: github.com/EmergeTools/Pow/blob/main/Sources/Pow/Transitions/Blur.swift
@MainActor final class CandidateInkMotion: UIView {
    private let sharp: UIImageView, middle: UIImageView, soft: UIImageView
    private var completion: (() -> Void)?
    init(image: UIImage) {
        sharp = UIImageView(image: image)
        middle = UIImageView(image: Self.blurred(image, radius: 1.4) ?? image)
        soft = UIImageView(image: Self.blurred(image, radius: 3.3) ?? image)
        super.init(frame: .zero)
        isUserInteractionEnabled = false; accessibilityElementsHidden = true
        backgroundColor = .clear; isOpaque = false
        [soft, middle, sharp].forEach { $0.isOpaque = false; $0.backgroundColor = .clear; addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); [soft, middle, sharp].forEach { $0.frame = bounds } }
    func run(appearing: Bool, completion: (() -> Void)? = nil) {
        self.completion = completion
        sharp.alpha = appearing ? 0 : 1; middle.alpha = 0; soft.alpha = appearing ? 0.55 : 0
        UIView.animateKeyframes(withDuration: appearing ? 0.18 : 0.15, delay: 0,
                               options: [.calculationModeLinear, .allowUserInteraction], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.5) {
                self.sharp.alpha = 0.15
                self.middle.alpha = 0.65; self.soft.alpha = 0.2
            }
            UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.5) {
                self.sharp.alpha = appearing ? 1 : 0
                self.middle.alpha = 0; self.soft.alpha = 0
            }
        }, completion: { [weak self] _ in self?.finish() })
    }
    func finish() {
        let callback = completion; completion = nil
        [sharp, middle, soft].forEach { $0.layer.removeAllAnimations() }
        callback?(); removeFromSuperview()
    }
    private static func blurred(_ image: UIImage, radius: CGFloat) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let width = source.width, height = source.height, row = width * 4
        var a = [UInt8](repeating: 0, count: row * height), b = a
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let kernel = UInt32(max(3, Int(radius * image.scale * 2) | 1))
        var output: UIImage?
        a.withUnsafeMutableBytes { first in
            b.withUnsafeMutableBytes { second in
                guard let context = CGContext(data: first.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: row, space: space, bitmapInfo: bitmap) else { return }
                context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
                var src = vImage_Buffer(data: first.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: row)
                var dst = vImage_Buffer(data: second.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: row)
                // Three separable box passes approximate Gaussian blur. No GPU
                // readback, opaque snapshot, or per-frame image filter is used.
                for _ in 0..<3 {
                    guard vImageBoxConvolve_ARGB8888(&src, &dst, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError else { return }
                    swap(&src, &dst)
                }
                let data = Data(bytes: src.data, count: row * height)
                guard let provider = CGDataProvider(data: data as CFData),
                      let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: row, space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmap),
                                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
                output = UIImage(cgImage: cg, scale: image.scale, orientation: .up)
            }
        }
        return output
    }
}
