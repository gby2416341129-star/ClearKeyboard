import Foundation

public struct EmoticonEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable { case wechat, emoji, kaomoji }
    public struct Sprite: Codable, Hashable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
    }
    public let id: String
    public let name: String
    /// Exact text inserted into the host. WeChat codes are not native sticker objects.
    public let code: String
    public let kind: Kind
    public let group: String
    public let aliases: [String]
    public let sprite: Sprite?
    public var hasImage: Bool { sprite != nil }
}

public struct EmoticonGroup: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
}

/// Local, finite source catalog. It suggests optional symbols; it never selects
/// a Chinese/English candidate or changes what Space/Enter commits.
public struct EmoticonCatalog: Sendable {
    private struct Document: Decodable { let entries: [EmoticonEntry] }
    public static let shared = EmoticonCatalog()
    public let entries: [EmoticonEntry]
    public let groups: [EmoticonGroup]
    private let byCode: [String: EmoticonEntry]
    private let byToken: [String: [Int]]
    private let committedTokens: [String]

    private init() {
        let loaded: [EmoticonEntry]
        if let url = InputResources.url("catalog", extension: "json", directory: "Emoticons"),
           let data = try? Data(contentsOf: url), data.count <= 1_048_576,
           let document = try? JSONDecoder().decode(Document.self, from: data) {
            var seen = Set<String>()
            loaded = document.entries.filter { entry in
                !entry.id.isEmpty && !entry.name.isEmpty && !entry.code.isEmpty &&
                entry.code.utf16.count <= 128 && seen.insert(entry.id).inserted &&
                (entry.sprite.map { $0.x >= 0 && $0.y >= 0 && $0.width > 0 && $0.height > 0 } ?? true)
            }
        } else { loaded = [] }
        entries = loaded
        let definitions = [
            EmoticonGroup(id: "wechat-face", title: "微信表情"),
            EmoticonGroup(id: "wechat-gesture", title: "手势心意"),
            EmoticonGroup(id: "wechat-object", title: "物品庆祝"),
            EmoticonGroup(id: "wechat-code", title: "更多代码"),
            EmoticonGroup(id: "emoji", title: "Emoji"),
            EmoticonGroup(id: "kaomoji", title: "颜文字")
        ]
        let available = Set(loaded.map(\.group))
        groups = definitions.filter { available.contains($0.id) }
        var codes: [String: EmoticonEntry] = [:]
        var tokens: [String: [Int]] = [:]
        for (index, entry) in loaded.enumerated() {
            if codes[entry.code] == nil { codes[entry.code] = entry }
            // These four panel actions are handed to the original image-sticker
            // callback. They are not extra word candidates or automatic inserts.
            if entry.id.hasPrefix("legacy-sticker-") { continue }
            var names = entry.aliases + [entry.name, entry.code]
            // Derived search keys only. The exact upstream code and original
            // capitalization remain unchanged in the selected entry.
            if let latin = entry.name.applyingTransform(.toLatin, reverse: false) { names.append(latin) }
            var unique = Set<String>()
            for name in names {
                let token = Self.normalized(name)
                guard !token.isEmpty, unique.insert(token).inserted else { continue }
                tokens[token, default: []].append(index)
            }
        }
        byCode = codes
        byToken = tokens
        // Only substantial Chinese meanings or complete Latin tokens participate
        // in post-commit suggestions; unrelated substring matches are not intents.
        committedTokens = tokens.keys.filter { token in
            token.count >= 2 && token.count <= 16 && token != "666" &&
            token.unicodeScalars.allSatisfy { Self.isHan($0) || CharacterSet.lowercaseLetters.contains($0) }
        }.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    }

    public var isAvailable: Bool { !entries.isEmpty }
    public var imageEntryCount: Int { entries.filter(\.hasImage).count }
    public func entry(forCode code: String) -> EmoticonEntry? { byCode[code] }
    public func entries(in group: String) -> [EmoticonEntry] { entries.filter { $0.group == group } }
    public func spriteURL() -> URL? {
        InputResources.url("wechat-source-sprite", extension: "png", directory: "Emoticons")
    }

    /// Exact semantic/pinyin aliases and bounded laughter forms. Callers append
    /// these after ordinary language choices and bind selection to the same raw.
    public func suggestions(for raw: String, limit: Int = 8) -> [EmoticonEntry] {
        let token = Self.normalized(raw)
        guard !token.isEmpty, token.count <= 64, limit > 0 else { return [] }
        if Self.isLaughter(token) {
            return orderedCodes(["[偷笑]", "[憨笑]", "[呲牙]", "[破涕为笑]", "[捂脸]", "[奸笑]", "[笑脸]"], limit: limit)
        }
        return matching(token, limit: limit)
    }

    /// Intended only after a real host commit, with no active composition or
    /// selection. Returned symbols are optional insertions and consume no raw.
    public func suggestions(afterCommittedText text: String, limit: Int = 8) -> [EmoticonEntry] {
        guard limit > 0 else { return [] }
        let tail = String(text.suffix(48)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !tail.isEmpty else { return [] }
        let folded = tail.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
        if Self.isLaughter(Self.normalized(tail)) { return suggestions(for: tail, limit: limit) }
        for token in committedTokens where folded.hasSuffix(token) {
            let preceding = folded.dropLast(token.count)
            if token.unicodeScalars.allSatisfy({ $0.value < 128 }),
               let last = preceding.unicodeScalars.last, CharacterSet.letters.contains(last) { continue }
            return suggestions(for: token, limit: limit)
        }
        return []
    }

    /// Panel-only search. A prefix here narrows visible items; it does not add
    /// predicted text to language candidates or force a match into the decoder.
    public func search(_ query: String, group: String? = nil) -> [EmoticonEntry] {
        let token = Self.normalized(query)
        guard !token.isEmpty else { return group.map { entries(in: $0) } ?? entries }
        let exact = Set(byToken[token] ?? [])
        return entries.enumerated().filter { index, entry in
            guard group == nil || entry.group == group else { return false }
            return exact.contains(index) || Self.normalized(entry.name).contains(token) ||
                entry.aliases.contains { Self.normalized($0).hasPrefix(token) }
        }.map(\.element)
    }

    private func matching(_ token: String, limit: Int) -> [EmoticonEntry] {
        var seen = Set<String>()
        return (byToken[token] ?? []).compactMap { index -> EmoticonEntry? in
            let entry = entries[index]
            return seen.insert(entry.code).inserted ? entry : nil
        }.prefix(min(limit, 32)).map { $0 }
    }
    private func orderedCodes(_ codes: [String], limit: Int) -> [EmoticonEntry] {
        Array(codes.compactMap { byCode[$0] }.prefix(min(limit, 32)))
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .filter { !$0.isWhitespace && $0 != "'" }
    }
    private static func isHan(_ value: Unicode.Scalar) -> Bool {
        (0x3400...0x9fff).contains(value.value) || (0x20000...0x323af).contains(value.value)
    }
    private static func isLaughter(_ token: String) -> Bool {
        if token.count >= 2 && token.count <= 16 && token.allSatisfy({ $0 == "h" }) { return true }
        if token.count >= 2 && token.count <= 12 && token.allSatisfy({ $0 == "哈" }) { return true }
        guard token.count >= 3, token.count <= 24 else { return false }
        var remaining = token[...]
        while remaining.hasPrefix("ha") { remaining = remaining.dropFirst(2) }
        return remaining.isEmpty || remaining == "h"
    }
}
