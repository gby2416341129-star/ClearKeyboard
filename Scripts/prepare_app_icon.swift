import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main enum PrepareAppIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let original = root.appendingPathComponent("SharedUI/Resources/BrandMark.png")
        guard let source = CGImageSourceCreateWithURL(original as CFURL,nil),
              let bitmap = CGImageSourceCreateImageAtIndex(source,0,nil),
              let mark = BrandMaterial.image(bitmap) else { fatalError("Cannot prepare the approved brand mark") }
        let assets = root.appendingPathComponent("App/ClearAppIcon.icon/Assets")
        let review = root.appendingPathComponent(".build/IconSourceReview")
        try FileManager.default.createDirectory(at: assets,withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: review,withIntermediateDirectories: true)
        func write(_ image: CGImage,to url: URL) {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { fatalError("Cannot write icon") }
            CGImageDestinationAddImage(destination,image,nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        write(mark,to: assets.appendingPathComponent("BrandMark.png"))
        write(mark,to: review.appendingPathComponent("approved-transparent-foreground.png"))
        guard let context = CGContext(data: nil,width: 1024,height: 1024,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Cannot prepare legacy icon") }
        // Older iOS versions require a flattened icon; match the app canvas,
        // keeping the approved mark and removing the previous white backplate.
        context.setFillColor(CGColor(red: 0.07,green: 0.07,blue: 0.09,alpha: 1))
        context.fill(CGRect(x: 0,y: 0,width: 1024,height: 1024))
        context.interpolationQuality = .high
        context.draw(mark,in: CGRect(x: 0,y: 0,width: 1024,height: 1024))
        let legacy = context.makeImage()!
        write(legacy,to: root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
        write(legacy,to: review.appendingPathComponent("legacy-no-white-backplate.png"))
        let foreground = try Data(contentsOf: assets.appendingPathComponent("BrandMark.png"))
        let report: [String:Any] = ["sourceCommit":ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "local", "sourceSHA256":SHA256.hash(data: try Data(contentsOf: original)).map { String(format:"%02x",$0) }.joined(), "foregroundSHA256":SHA256.hash(data: foreground).map { String(format:"%02x",$0) }.joined(), "materialRecipe":"SharedUI/BrandMaterial.swift", "backgroundFill":"#121217", "extraSpecular":false, "legacyBackground":"#121217", "sourceDimensions":[bitmap.width,bitmap.height]]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: review.appendingPathComponent("icon-source.json"))
        print("APP_ICON_PREPARED transparentForeground=true whiteBackplate=false sharedRuntimeRecipe=true")
    }
}
