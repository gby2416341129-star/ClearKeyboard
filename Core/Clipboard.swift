import Foundation
import CryptoKit
import CoreFoundation

/// Clipboard contents are shared, but the system's access decision belongs to
/// the process that reads them. An extension attempt cannot stand in for an
/// attempt by its containing app, including a denied attempt.
struct ClipboardObservation {
    enum Owner: String { case app, keyboard }
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults, owner: Owner) {
        self.defaults = defaults
        key = "clear.clipboard.observedChangeCount.v2." + owner.rawValue
    }
    func shouldRead(changeCount: Int, hasContent: Bool) -> Bool {
        hasContent && (defaults.object(forKey: key) == nil || defaults.integer(forKey: key) != changeCount)
    }
    func didAttempt(changeCount: Int) { defaults.set(changeCount, forKey: key) }
    func didCapture(changeCount: Int) { defaults.set(changeCount, forKey: "clear.clipboard.capturedChangeCount.v3") }
    func retry() { defaults.removeObject(forKey: key) }
}

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
        id = UUID(); self.text = text; self.createdAt = createdAt; self.pinned = pinned
        self.attachment = attachment
    }
}
public final class ClipboardStore {
    public static let itemLimit = 200
    public static let attachmentLimit = 8 * 1_024 * 1_024
    public static let totalAttachmentLimit = 32 * 1_024 * 1_024
    public static let textLimit = 2 * 1_024 * 1_024
    public static let totalTextLimit = 8 * 1_024 * 1_024
    public static let changed = Notification.Name("clear.clipboard.store.changed")
    public enum Failure: Error, Equatable { case capacity, unreadable, unavailable }
    private let url: URL
    public private(set) var clips: [Clip] = []
    public private(set) var lastError: Failure?
    private struct Cached { let stamp: String; let clips: [Clip] }
    private static let cacheLock = NSLock()
    private static var cache: [String: Cached] = [:]
    public init(url: URL) {
        self.url = url
        do { clips = try Self.read(url) } catch { lastError = .unreadable }
    }
    private static func read(_ url: URL) throws -> [Clip] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= totalTextLimit * 2 else { throw Failure.capacity }
        let stamp = "\((attributes[.modificationDate] as? Date ?? .distantPast).timeIntervalSince1970)-\(attributes[.systemFileNumber] as? NSNumber ?? 0)-\(size)"
        cacheLock.lock(); let cached = cache[url.path]; cacheLock.unlock()
        if cached?.stamp == stamp { return cached!.clips }
        let values = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: url, options: .mappedIfSafe))
        guard values.count <= itemLimit else { throw Failure.capacity }
        cacheLock.lock()
        if cache.count >= 4 { cache.removeAll() }
        cache[url.path] = Cached(stamp: stamp, clips: values); cacheLock.unlock()
        return values
    }
    @discardableResult private func transaction(_ edit: (inout [Clip]) throws -> Bool) -> Bool {
        do {
            let changed = try SharedFileLock.perform(at: url.appendingPathExtension("lock")) {
                let previous = try Self.read(url)
                var next = previous
                guard try edit(&next) else { throw Failure.capacity }
                guard next != previous else { clips = previous; return false }
                let data = try JSONEncoder().encode(next)
                guard data.count <= Self.totalTextLimit * 2 else { throw Failure.capacity }
                #if os(iOS)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                #else
                try data.write(to: url, options: .atomic)
                #endif
                Self.cacheLock.lock(); Self.cache.removeValue(forKey: url.path); Self.cacheLock.unlock()
                clips = next
                removeUnusedAssets(previous)
                _ = try? Self.read(url)
                return true
            }
            lastError = nil
            if changed {
                NotificationCenter.default.post(name: Self.changed, object: url)
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(rawValue: "com.clearkeyboard.clipboard.history.changed.v1" as CFString), nil, nil, true)
            }
            return true
        } catch {
            lastError = (error as? Failure) ?? .unavailable
            return false
        }
    }
    private static func trim(_ values: inout [Clip]) {
        var textBytes = values.reduce(0) { $0 + ($1.attachment == nil ? $1.text.utf8.count : 0) }
        var attachmentBytes = values.reduce(0) { $0 + ($1.attachment?.byteCount ?? 0) }
        while values.count > itemLimit || textBytes > totalTextLimit || attachmentBytes > totalAttachmentLimit {
            guard let index = values.lastIndex(where: { !$0.pinned }) else { break }
            let removed = values.remove(at: index)
            textBytes -= removed.attachment == nil ? removed.text.utf8.count : 0
            attachmentBytes -= removed.attachment?.byteCount ?? 0
        }
    }
    @discardableResult public func prune(lifetime: TimeInterval, now: Date = Date()) -> Bool {
        guard lifetime > 0, lifetime.isFinite else { return true }
        return transaction { values in
            values.removeAll { !$0.pinned && now.timeIntervalSince($0.createdAt) > lifetime }; return true
        }
    }
    @discardableResult public func add(_ text: String, now: Date = Date()) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text.utf8.count <= Self.textLimit else { lastError = .capacity; return false }
        return transaction { values in
            let pinned = values.first { $0.attachment == nil && $0.text == text }?.pinned ?? false
            let value = Clip(text: text, createdAt: now, pinned: pinned)
            values.removeAll { $0.attachment == nil && $0.text == text }; values.insert(value, at: 0)
            Self.trim(&values); return values.contains { $0.id == value.id }
        }
    }
    @discardableResult public func addAttachment(_ data: Data, typeIdentifier: String, name: String, now: Date = Date()) -> Bool {
        guard !data.isEmpty, data.count <= Self.attachmentLimit else { lastError = .capacity; return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = digest + ".bin"
        guard let asset = assetURL(filename) else { return false }
        let existed = FileManager.default.fileExists(atPath: asset.path)
        let saved = transaction { values in
            try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            let pinned = values.first { $0.attachment?.filename == filename }?.pinned ?? false
            let value = Clip(text: name, createdAt: now, pinned: pinned, attachment: ClipAttachment(filename: filename, typeIdentifier: typeIdentifier, byteCount: data.count))
            values.removeAll { $0.attachment?.filename == filename }; values.insert(value, at: 0)
            Self.trim(&values)
            guard values.contains(where: { $0.id == value.id }) else { return false }
            #if os(iOS)
            try data.write(to: asset, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: asset, options: .atomic)
            #endif
            return true
        }
        if !saved && !existed {
            try? SharedFileLock.perform(at: url.appendingPathExtension("lock")) {
                let sibling = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent == "clipboard.json" ? "common-phrases.json" : "clipboard.json")
                let referenced = try Self.read(url) + Self.read(sibling)
                if !referenced.contains(where: { $0.attachment?.filename == filename }) { try? FileManager.default.removeItem(at: asset) }
            }
        }
        return saved
    }
    public static func boundedAttachment(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size > 0, size <= attachmentLimit else { throw Failure.capacity }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: attachmentLimit + 1) ?? Data()
        guard !data.isEmpty, data.count <= attachmentLimit else { throw Failure.capacity }
        return data
    }
    public func attachmentData(for clip: Clip) -> Data? {
        guard let attachment = clip.attachment, let asset = assetURL(attachment.filename) else { return nil }
        return try? Self.boundedAttachment(at: asset)
    }
    private func assetURL(_ filename: String) -> URL? {
        guard filename.count == 68, filename.hasSuffix(".bin"), filename.prefix(64).allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("ClipboardAssets", isDirectory: true).appendingPathComponent(filename)
    }
    private func removeUnusedAssets(_ previous: [Clip]) {
        let other = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent == "clipboard.json" ? "common-phrases.json" : "clipboard.json")
        // A legacy phrase store can refer to the same content-addressed asset.
        guard let otherClips = try? Self.read(other) else { return }
        let used = Set((clips + otherClips).compactMap { $0.attachment?.filename })
        for name in Set(previous.compactMap { $0.attachment?.filename }).subtracting(used) {
            if let asset = assetURL(name) { try? FileManager.default.removeItem(at: asset) }
        }
    }
    @discardableResult public func delete(_ id: UUID) -> Bool {
        transaction { values in values.removeAll { $0.id == id }; return true }
    }
    @discardableResult public func togglePin(_ id: UUID) -> Bool {
        transaction { values in
            guard let index = values.firstIndex(where: { $0.id == id }) else { return true }
            if !values[index].pinned && values.filter(\.pinned).count >= 10 { return false }
            values[index].pinned.toggle(); return true
        }
    }
    @discardableResult public func clear() -> Bool { transaction { values in values = []; return true } }
    @discardableResult public func mergeLegacy(from source: URL) -> Bool {
        do {
            let legacy = try Self.read(source)
            return transaction { values in
                for clip in legacy where !values.contains(where: { $0.text == clip.text && $0.attachment == clip.attachment }) {
                    if let attachment = clip.attachment, let target = assetURL(attachment.filename), !FileManager.default.fileExists(atPath: target.path) {
                        let old = source.deletingLastPathComponent().appendingPathComponent("ClipboardAssets/" + attachment.filename)
                        let data = try Self.boundedAttachment(at: old)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: target, options: .atomic)
                    }
                    values.append(clip)
                }
                values.sort { $0.createdAt > $1.createdAt }; Self.trim(&values); return true
            }
        } catch { lastError = .unreadable; return false }
    }
}
