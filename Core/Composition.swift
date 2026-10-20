import Foundation

public struct Composition: Equatable {
    public static let maximumLength = 256
    public private(set) var raw = ""
    public private(set) var normalized = ""
    private var asciiRaw = true
    public var isEmpty: Bool { normalized.isEmpty }
    public init() {}
    @discardableResult public mutating func append(_ text: String) -> Bool {
        let addition = FuzzyPinyin.normalize(text)
        guard normalized.utf8.count + addition.utf8.count <= Self.maximumLength else { return false }
        asciiRaw = asciiRaw && text.utf8.allSatisfy { $0 < 128 }
        raw += text
        if asciiRaw { normalized += addition }
        else { normalized = FuzzyPinyin.normalize(raw) }
        return true
    }
    public mutating func deleteBackward() {
        guard let last = raw.last else { return }
        let removed = FuzzyPinyin.normalize(String(last)).utf8.count
        raw.removeLast()
        if removed > 0 { normalized.removeLast(min(removed, normalized.utf8.count)) }
        if !asciiRaw { asciiRaw = raw.utf8.allSatisfy { $0 < 128 }; normalized = FuzzyPinyin.normalize(raw) }
    }
    public mutating func clear() { raw = ""; normalized = ""; asciiRaw = true }
    public mutating func consume(_ count: Int) {
        guard count > 0 else { return }
        var consumed = 0, end = raw.startIndex
        while end < raw.endIndex && consumed < count {
            let character = raw[end]
            if let byte = character.asciiValue {
                if (65...90).contains(byte) || (97...122).contains(byte) { consumed += 1 }
            } else if !FuzzyPinyin.normalize(String(character)).isEmpty { consumed += 1 }
            raw.formIndex(after: &end)
        }
        while end < raw.endIndex && raw[end] == "'" { raw.formIndex(after: &end) }
        raw = String(raw[end...])
        normalized.removeFirst(min(consumed, normalized.utf8.count))
        if !asciiRaw { asciiRaw = raw.utf8.allSatisfy { $0 < 128 }; normalized = FuzzyPinyin.normalize(raw) }
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
