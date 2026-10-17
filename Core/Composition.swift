import Foundation

public struct Composition: Equatable {
    public private(set) var raw = ""
    public var normalized: String { FuzzyPinyin.normalize(raw) }
    public var isEmpty: Bool { normalized.isEmpty }
    public init() {}
    @discardableResult public mutating func append(_ text: String) -> Bool {
        guard normalized.count + FuzzyPinyin.normalize(text).count <= 64 else { return false }
        raw += text; return true
    }
    public mutating func deleteBackward() { if !raw.isEmpty { raw.removeLast() } }
    public mutating func clear() { raw = "" }
    public mutating func consume(_ count: Int) {
        guard count > 0 else { return }
        var consumed = 0
        while !raw.isEmpty && consumed < count {
            let character = raw.removeFirst()
            if !FuzzyPinyin.normalize(String(character)).isEmpty { consumed += 1 }
        }
        while raw.first == "'" { raw.removeFirst() }
    }
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
