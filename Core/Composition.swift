import Foundation

/// Host editing state only. All linguistic normalization and segmentation belong to V21.
public struct Composition: Equatable {
    public static let maximumQueryLength = 384
    public private(set) var raw = ""
    public var normalized: String { raw }
    public var isEmpty: Bool { raw.isEmpty }
    public init() {}
    @discardableResult public mutating func append(_ text: String) -> Bool { raw += text; return true }
    public mutating func deleteBackward() { if !raw.isEmpty { raw.removeLast() } }
    public mutating func clear() { raw = "" }
    public mutating func replace(with remainingPinyin: String) { raw = remainingPinyin }
}
public enum EnglishContext {
    public static func word(in context: String) -> String {
        String(context.reversed().prefix { $0.isASCII && ($0.isLetter || $0 == "'") }.reversed())
    }
    public static func applyingCase(_ suggestion: String, like word: String) -> String {
        if word.count > 1 && word == word.uppercased() { return suggestion.uppercased() }
        if word.first?.isUppercase == true { return suggestion.prefix(1).uppercased() + suggestion.dropFirst() }
        return suggestion
    }
}
