import Foundation

/// Exact, offline recognition of dictionary English words. It does not guess
/// that an arbitrary Latin/pinyin string is English, and never changes user text.
public struct EnglishWordLexicon: Sendable {
    public static let shared = EnglishWordLexicon()

    private let bytes: [UInt8]
    private let starts: [UInt32]

    public var wordCount: Int { starts.count }
    public var isAvailable: Bool { !starts.isEmpty }

    private init() {
        guard let url = InputResources.url("words", extension: "txt", directory: "EnglishWords"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
            bytes = []; starts = []; return
        }
        let values = Array(data)
        guard values.last == 10 else { bytes = []; starts = []; return }
        var positions: [UInt32] = [0]
        positions.reserveCapacity(values.count / 8)
        if values.count > 1 {
            for i in 0..<(values.count - 1) where values[i] == 10 {
                positions.append(UInt32(i + 1))
            }
        }
        bytes = values
        starts = positions
    }

    /// Only the lookup key is ASCII case-folded. The caller should construct the
    /// displayed/committed candidate using its original `raw`, including case.
    public func isWord(_ raw: String) -> Bool {
        guard !starts.isEmpty, !raw.isEmpty, raw.utf8.count <= 64 else { return false }
        var key: [UInt8] = []
        key.reserveCapacity(raw.utf8.count)
        for byte in raw.utf8 {
            switch byte {
            case 65...90: key.append(byte + 32)
            case 97...122, 39, 45: key.append(byte)
            default: return false
            }
        }
        var lower = 0, upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let order = compare(key, at: middle)
            if order == 0 { return true }
            if order < 0 { upper = middle } else { lower = middle + 1 }
        }
        return false
    }

    private func compare(_ key: [UInt8], at word: Int) -> Int {
        let begin = Int(starts[word])
        let end = word + 1 < starts.count ? Int(starts[word + 1]) - 1 : bytes.count - 1
        let length = end - begin
        for i in 0..<min(key.count, length) {
            if key[i] < bytes[begin + i] { return -1 }
            if key[i] > bytes[begin + i] { return 1 }
        }
        if key.count == length { return 0 }
        return key.count < length ? -1 : 1
    }
}
