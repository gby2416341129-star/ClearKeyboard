import Foundation

public struct Composition: Equatable {
    /// Bound decoder work, not how much unconfirmed text the user may type.
    public static let maximumQueryLength = 256
    public private(set) var raw = ""
    public private(set) var normalized = ""
    private var asciiRaw = true
    public var isEmpty: Bool { normalized.isEmpty }
    public init() {}
    @discardableResult public mutating func append(_ text: String) -> Bool {
        let addition = FuzzyPinyin.normalize(text)
        asciiRaw = asciiRaw && text.utf8.allSatisfy { $0 < 128 }
        raw += text
        if asciiRaw { normalized += addition }
        else { normalized = FuzzyPinyin.normalize(raw) }
        return true
    }
    /// A long draft stays intact while the decoder offers selectable prefixes.
    /// Leave lookahead so the cut normally falls at a complete syllable.
    static func queryPrefix(_ raw: String, normalized: String) -> String {
        guard normalized.utf8.count > maximumQueryLength else { return raw }
        let probe = String(normalized.prefix(maximumQueryLength))
        let count = PinyinSpelling.prefixBoundary(probe, noLaterThan: maximumQueryLength / 2)
        var remainder = Composition(); remainder.raw = raw; remainder.normalized = normalized
        remainder.asciiRaw = raw.utf8.allSatisfy { $0 < 128 }
        remainder.consume(count)
        return String(raw.dropLast(remainder.raw.count))
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
