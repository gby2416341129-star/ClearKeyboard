import Foundation

internal struct V21Input {
    let original: String
    let normalized: String
    let starts: [Int32]
    let ends: [Int32]
    let map: [V21NormalizationUnit]
    static func normalize(_ raw: String) throws -> V21Input {
        guard raw.utf8.count <= 4096 else { throw V21Error.contract("Raw input exceeds the bounded input buffer") }
        var normalized = "", starts: [Int32] = [], ends: [Int32] = [], mapping: [V21NormalizationUnit] = []
        var utf8Offset = 0, utf16Offset = 0
        for character in raw {
            let original = String(character)
            // NFC + Unicode lowercase, as in V21 parse(). No ü→v, fuzzy or typo rewrite.
            let unit = original.precomposedStringWithCanonicalMapping.lowercased()
            let bytes = Array(unit.utf8)
            guard bytes.allSatisfy({ (97...122).contains($0) || $0 == 39 || $0 == 32 }) else {
                throw V21Error.contract("Only complete a-z/v pinyin, apostrophes and ASCII spaces are supported")
            }
            let first = normalized.utf8.count
            normalized += unit
            for _ in bytes { starts.append(Int32(utf8Offset)); ends.append(Int32(utf8Offset + original.utf8.count)) }
            mapping.append(V21NormalizationUnit(
                normalizedUTF8Range: V21Range(start: first, end: first + bytes.count),
                originalUTF8Range: V21Range(start: utf8Offset, end: utf8Offset + original.utf8.count),
                originalUTF16Range: V21Range(start: utf16Offset, end: utf16Offset + original.utf16.count)))
            utf8Offset += original.utf8.count; utf16Offset += original.utf16.count
        }
        guard normalized.utf8.count <= 384 else { throw V21Error.contract("Normalized pinyin exceeds V21's 384-letter limit") }
        return V21Input(original: raw, normalized: normalized, starts: starts, ends: ends, map: mapping)
    }
    static func utf16Range(_ bytes: V21Range, in raw: String) throws -> V21Range {
        guard bytes.start >= 0, bytes.end >= bytes.start, bytes.end <= raw.utf8.count else { throw V21Error.contract("Invalid UTF-8 byte range") }
        let a = raw.utf8.index(raw.utf8.startIndex, offsetBy: bytes.start)
        let b = raw.utf8.index(raw.utf8.startIndex, offsetBy: bytes.end)
        guard let start = String.Index(a, within: raw), let end = String.Index(b, within: raw) else { throw V21Error.contract("Range splits an original Unicode character") }
        return V21Range(start: raw[..<start].utf16.count, end: raw[..<end].utf16.count)
    }
    static func suffix(after bytes: Int, in raw: String) throws -> String {
        let range = V21Range(start: bytes, end: raw.utf8.count)
        _ = try utf16Range(range, in: raw)
        let at = raw.utf8.index(raw.utf8.startIndex, offsetBy: bytes)
        guard let index = String.Index(at, within: raw) else { throw V21Error.contract("Invalid remaining-input boundary") }
        return String(raw[index...])
    }
    static func candidateID(raw: String, text: String, reading: String, consumedEnd: Int) -> String {
        var value: UInt64 = 14695981039346656037
        for byte in (raw + "\0" + text + "\0" + reading + "\0" + String(consumedEnd)).utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%016llx", value)
    }
}
