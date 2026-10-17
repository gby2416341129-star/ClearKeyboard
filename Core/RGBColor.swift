import Foundation

public struct RGBColor: Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, value.allSatisfy(\.isHexDigit), let rgb = UInt32(value, radix: 16) else { return nil }
        red = Double((rgb >> 16) & 255) / 255
        green = Double((rgb >> 8) & 255) / 255
        blue = Double(rgb & 255) / 255
    }
    public init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red)); self.green = min(1, max(0, green)); self.blue = min(1, max(0, blue))
    }
    public var hex: String { String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())) }
}
