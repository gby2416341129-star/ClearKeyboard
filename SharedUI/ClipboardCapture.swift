import UIKit
import UniformTypeIdentifiers

/// Event-driven capture: there is no timer, background task, or content polling.
@MainActor final class ClipboardCapture {
    private var observer: NSObjectProtocol?
    private var active = false
    private var settings = KeyboardSettings()
    private let defaults: UserDefaults
    private let makeStore: () -> ClipboardStore
    private let changeCount: () -> Int
    private let hasStrings: () -> Bool
    private let readText: () -> String?
    private let readAttachment: () -> (Data, String, String)?
    private let notificationName: Notification.Name
    private static let observedKey = "clear.clipboard.observedChangeCount.v1"
    var onCapture: (() -> Void)?

    init(defaults: UserDefaults? = nil, makeStore: (() -> ClipboardStore)? = nil,
         changeCount: (() -> Int)? = nil, hasStrings: (() -> Bool)? = nil,
         readText: (() -> String?)? = nil, readAttachment: (() -> (Data, String, String)?)? = nil, notificationName: Notification.Name = UIPasteboard.changedNotification) {
        self.defaults = defaults ?? SharedStorage.defaults(allowShared: true)
        self.makeStore = makeStore ?? { ClipboardStore(url: SharedStorage.clipboardURL(allowShared: true)) }
        self.changeCount = changeCount ?? { UIPasteboard.general.changeCount }
        self.hasStrings = hasStrings ?? { UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs }
        self.readText = readText ?? { UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString }
        if let readAttachment { self.readAttachment = readAttachment }
        else if readText != nil { self.readAttachment = { nil } }
        else { self.readAttachment = { Self.systemAttachment() } }
        self.notificationName = notificationName
    }
    func activate(settings: KeyboardSettings, allowed: Bool) {
        self.settings = settings
        guard allowed, settings.capturesClipboard else { stop(); return }
        active = true
        makeStore().prune(lifetime: settings.clipboardLifetimeHours * 3600)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.captureIfChanged() }
            }
        }
        captureIfChanged()
    }
    func captureIfChanged() {
        guard active else { return }
        let count = changeCount()
        guard defaults.object(forKey: Self.observedKey) == nil || defaults.integer(forKey: Self.observedKey) != count else { return }
        // Remember denied/empty attempts too, so one copy cannot trigger repeated permission prompts.
        defaults.set(count, forKey: Self.observedKey)
        if saveCurrentContent() { onCapture?() }
    }
    @discardableResult func captureManually() -> Bool {
        let saved = saveCurrentContent()
        defaults.set(changeCount(), forKey: Self.observedKey)
        if saved { onCapture?() }; return saved
    }
    func retryAfterPermissionChange() { defaults.removeObject(forKey: Self.observedKey); captureIfChanged() }
    func acceptText(_ text: String) {
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600); store.add(text)
        defaults.set(changeCount(), forKey: Self.observedKey); onCapture?()
    }
    func acceptAttachment(_ data: Data, typeIdentifier: String, name: String) {
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600)
        if store.addAttachment(data, typeIdentifier: typeIdentifier, name: name) { defaults.set(changeCount(), forKey: Self.observedKey); onCapture?() }
    }
    private func saveCurrentContent() -> Bool {
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600)
        if let (data, type, name) = readAttachment() { return store.addAttachment(data, typeIdentifier: type, name: name) }
        guard hasStrings(), let text = readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        store.add(text); return true
    }
    private static func systemAttachment() -> (Data, String, String)? {
        let board = UIPasteboard.general
        if board.hasImages {
            for type in ["public.png", "public.jpeg", "public.heic"] {
                if let data = board.data(forPasteboardType: type) { return (data, type, "图片") }
            }
            if let data = board.image?.jpegData(compressionQuality: 0.85) { return (data, "public.jpeg", "图片") }
        }
        guard !board.hasStrings, !board.hasURLs else { return nil }
        for item in board.items {
            for (type, value) in item {
                if let data = value as? Data, UTType(type)?.conforms(to: .data) == true {
                    return (data, type, UTType(type)?.localizedDescription ?? "附件")
                }
            }
        }
        return nil
    }
    func stop() {
        active = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
