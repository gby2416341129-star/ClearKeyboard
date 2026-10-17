import Foundation
import CryptoKit

public struct ClipAttachment: Codable, Equatable {
    public let filename: String
    public let typeIdentifier: String
    public let byteCount: Int
}

public struct Clip: Codable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public var pinned: Bool
    public let attachment: ClipAttachment?
    public init(text: String, createdAt: Date = Date(), pinned: Bool = false, attachment: ClipAttachment? = nil) {
        id = UUID(); self.text = String(text.prefix(2_000)); self.createdAt = createdAt; self.pinned = pinned
        self.attachment = attachment
    }
}
public final class ClipboardStore {
    public static let itemLimit = 200
    public static let attachmentLimit = 8 * 1_024 * 1_024
    public static let totalAttachmentLimit = 32 * 1_024 * 1_024
    private let url: URL
    public private(set) var clips: [Clip] = []
    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([Clip].self, from: data) {
            clips = Array(stored.prefix(Self.itemLimit))
        }
    }
    public func prune(lifetime: TimeInterval, now: Date = Date()) {
        guard lifetime > 0, lifetime.isFinite else { return }
        let previous = clips
        clips.removeAll { !$0.pinned && now.timeIntervalSince($0.createdAt) > lifetime }
        if clips != previous { persist(); removeUnusedAssets(previous) }
    }
    public func add(_ text: String, now: Date = Date()) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let previous = clips
        let clean = String(text.prefix(2_000))
        if let old = clips.first(where: { $0.attachment == nil && $0.text == clean && $0.pinned }) { clips.removeAll { $0.id == old.id }; clips.insert(old, at: 0) }
        else { clips.removeAll { $0.attachment == nil && $0.text == clean }; clips.insert(Clip(text: clean, createdAt: now), at: 0) }
        while clips.count > Self.itemLimit {
            if let index = clips.lastIndex(where: { !$0.pinned }) { clips.remove(at: index) } else { clips.removeLast() }
        }
        persist(); removeUnusedAssets(previous)
    }
    @discardableResult public func addAttachment(_ data: Data, typeIdentifier: String, name: String, now: Date = Date()) -> Bool {
        guard !data.isEmpty, data.count <= Self.attachmentLimit else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = digest + ".bin"
        guard let asset = assetURL(filename) else { return false }
        do {
            try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: asset, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: asset, options: .atomic)
            #endif
        } catch { return false }
        let previous = clips
        let pinned = clips.first { $0.attachment?.filename == filename }?.pinned ?? false
        clips.removeAll { $0.attachment?.filename == filename }
        clips.insert(Clip(text: name, createdAt: now, pinned: pinned, attachment: ClipAttachment(filename: filename, typeIdentifier: typeIdentifier, byteCount: data.count)), at: 0)
        while clips.count > Self.itemLimit || clips.reduce(0, { $0 + ($1.attachment?.byteCount ?? 0) }) > Self.totalAttachmentLimit {
            guard let index = clips.lastIndex(where: { !$0.pinned }) else { break }
            clips.remove(at: index)
        }
        persist(); removeUnusedAssets(previous)
        let kept = clips.contains { $0.attachment?.filename == filename }
        if !kept { try? FileManager.default.removeItem(at: asset) }
        return kept
    }
    public func attachmentData(for clip: Clip) -> Data? {
        guard let attachment = clip.attachment, let asset = assetURL(attachment.filename) else { return nil }
        return try? Data(contentsOf: asset, options: .mappedIfSafe)
    }
    private func assetURL(_ filename: String) -> URL? {
        guard filename.count == 68, filename.hasSuffix(".bin"), filename.prefix(64).allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("ClipboardAssets", isDirectory: true).appendingPathComponent(filename)
    }
    private func removeUnusedAssets(_ previous: [Clip]) {
        let used = Set(clips.compactMap { $0.attachment?.filename })
        for name in Set(previous.compactMap { $0.attachment?.filename }).subtracting(used) {
            if let asset = assetURL(name) { try? FileManager.default.removeItem(at: asset) }
        }
    }
    public func delete(_ id: UUID) { let previous = clips; clips.removeAll { $0.id == id }; persist(); removeUnusedAssets(previous) }
    public func togglePin(_ id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        if !clips[index].pinned && clips.filter(\.pinned).count >= 10 { return }
        clips[index].pinned.toggle(); persist()
    }
    public func clear() { let previous = clips; clips = []; persist(); removeUnusedAssets(previous) }
    private func persist() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}
