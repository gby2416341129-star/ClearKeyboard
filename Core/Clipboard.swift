import Foundation

public struct Clip: Codable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public var pinned: Bool
    public init(text: String, createdAt: Date = Date(), pinned: Bool = false) {
        id = UUID(); self.text = String(text.prefix(2_000)); self.createdAt = createdAt; self.pinned = pinned
    }
}
public final class ClipboardStore {
    public static let itemLimit = 200
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
        if clips != previous { persist() }
    }
    public func add(_ text: String, now: Date = Date()) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let clean = String(text.prefix(2_000))
        if let old = clips.first(where: { $0.text == clean && $0.pinned }) { clips.removeAll { $0.id == old.id }; clips.insert(old, at: 0) }
        else { clips.removeAll { $0.text == clean }; clips.insert(Clip(text: clean, createdAt: now), at: 0) }
        while clips.count > Self.itemLimit {
            if let index = clips.lastIndex(where: { !$0.pinned }) { clips.remove(at: index) } else { clips.removeLast() }
        }
        persist()
    }
    public func delete(_ id: UUID) { clips.removeAll { $0.id == id }; persist() }
    public func togglePin(_ id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        if !clips[index].pinned && clips.filter(\.pinned).count >= 10 { return }
        clips[index].pinned.toggle(); persist()
    }
    public func clear() { clips = []; persist() }
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
