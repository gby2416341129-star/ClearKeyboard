import Foundation

public struct LexiconEntry: Equatable {
    public let key: String
    public let text: String
    public let reading: String
    public let frequency: UInt32
}
public enum LexiconError: Error { case invalidFormat, truncated }

/// A read-only, memory-mapped lexicon. No expanded trie or per-word objects are retained.
/// CLRX0001: header(32), entries(28 each), index(16 each), result IDs, UTF-8 blob.
public final class Lexicon {
    private let data: Data
    private let entryCount: Int
    private let indexCount: Int
    private let indexOffset: Int
    private let resultsOffset: Int
    private let stringsOffset: Int
    public var count: Int { entryCount }

    public init(url: URL) throws {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 32, String(data: bytes.prefix(8), encoding: .utf8) == "CLRX0001" else { throw LexiconError.invalidFormat }
        data = bytes
        func u32(_ offset: Int) -> Int { Int(bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }) }
        entryCount = u32(8); indexCount = u32(12); indexOffset = u32(16)
        resultsOffset = u32(20); stringsOffset = u32(24)
        guard u32(28) == bytes.count, indexOffset == 32 + entryCount * 28,
              resultsOffset == indexOffset + indexCount * 16,
              stringsOffset >= resultsOffset, stringsOffset <= bytes.count else { throw LexiconError.truncated }
        // Validate all bounds once on the background load queue, never on a keypress.
        for i in 0..<entryCount {
            let offset = 32 + i * 28
            for field in [0, 8, 16] {
                guard u32(offset + field) + u32(offset + field + 4) <= bytes.count - stringsOffset else { throw LexiconError.truncated }
            }
        }
        for i in 0..<indexCount {
            let offset = indexOffset + i * 16
            guard u32(offset) + u32(offset + 4) <= bytes.count - stringsOffset,
                  (u32(offset + 8) + u32(offset + 12)) * 4 <= stringsOffset - resultsOffset else { throw LexiconError.truncated }
        }
    }
    private func u32(_ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    private func string(_ offset: Int) -> String {
        let start = stringsOffset + Int(u32(offset)), length = Int(u32(offset + 4))
        return String(decoding: data[start..<(start + length)], as: UTF8.self)
    }
    public func entry(_ id: Int) -> LexiconEntry? {
        guard (0..<entryCount).contains(id) else { return nil }
        let base = 32 + id * 28
        return LexiconEntry(key: string(base), text: string(base + 8), reading: string(base + 16), frequency: u32(base + 24))
    }
    private func indexEntry(for key: String) -> Int? {
        let target = Array(key.utf8)
        // One mapped-byte access for the complete binary search, without nested Data access per field.
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            func number(_ offset: Int) -> Int { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            func compare(_ position: Int) -> Int {
                let base = indexOffset + position * 16
                let start = stringsOffset + number(base), length = number(base + 4)
                for i in 0..<min(length, target.count) {
                    if bytes[start + i] != target[i] { return bytes[start + i] < target[i] ? -1 : 1 }
                }
                return length == target.count ? 0 : (length < target.count ? -1 : 1)
            }
            var low = 0, high = indexCount
            while low < high { let mid = (low + high) / 2; if compare(mid) < 0 { low = mid + 1 } else { high = mid } }
            return low < indexCount && compare(low) == 0 ? indexOffset + low * 16 : nil
        }
    }
    public func contains(_ key: String) -> Bool { indexEntry(for: key) != nil }
    public func lookup(_ key: String, limit: Int = 24) -> [LexiconEntry] {
        guard let base = indexEntry(for: key) else { return [] }
        let start = Int(u32(base + 8)), count = min(max(0, limit), Int(u32(base + 12)))
        return (0..<count).compactMap { entry(Int(u32(resultsOffset + (start + $0) * 4))) }
    }
    public static func bundled(_ name: String) throws -> Lexicon {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "clx") else { throw LexiconError.invalidFormat }
        return try Lexicon(url: url)
    }
}
