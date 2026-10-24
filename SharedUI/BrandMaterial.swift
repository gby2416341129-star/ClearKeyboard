import Foundation
import CoreGraphics

/// The same approved transparent mark is used inside the app and by Icon Composer.
enum BrandMaterial {
    static func image(_ source: CGImage) -> CGImage? {
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0,count: width*height*4)
        return pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(source,in: CGRect(x: 0,y: 0,width: CGFloat(width),height: CGFloat(height)))
            for offset in stride(from: 0,to: raw.count,by: 4) {
                let alpha = Double(raw[offset+3])/255
                guard alpha > 0 else { continue }
                let red = Double(raw[offset])/255/alpha, green = Double(raw[offset+1])/255/alpha, blue = Double(raw[offset+2])/255/alpha
                let luminance = red*0.2126 + green*0.7152 + blue*0.0722
                let opacity = alpha*(0.25 + 0.63*pow(luminance,5))
                for (channel,value) in [red,green,blue].enumerated() {
                    let color = min(1,max(0,luminance+(value-luminance)*1.42))
                    raw[offset+channel] = UInt8((color*opacity*255).rounded())
                }
                raw[offset+3] = UInt8((opacity*255).rounded())
            }
            return context.makeImage()
        }
    }
}
