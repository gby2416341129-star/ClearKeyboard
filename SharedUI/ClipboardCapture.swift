import UIKit
import UniformTypeIdentifiers

/// Event-driven capture: there is no timer, background task, or content polling.
@MainActor final class ClipboardCapture {
    enum AccessCheck { case empty, contentRead, unavailable }
    private var observer: NSObjectProtocol?
    private var active = false
    private var settings = KeyboardSettings()
    private let observation: ClipboardObservation
    private let makeStore: () -> ClipboardStore
    private let changeCount: () -> Int
    private let hasStrings: () -> Bool
    private let hasContent: () -> Bool
    private let readText: () -> String?
    private let readAttachment: () -> (Data, String, String)?
    private let notificationName: Notification.Name
    var onCapture: (() -> Void)?

    init(defaults: UserDefaults? = nil, makeStore: (() -> ClipboardStore)? = nil,
         changeCount: (() -> Int)? = nil, hasStrings: (() -> Bool)? = nil, hasContent: (() -> Bool)? = nil,
         readText: (() -> String?)? = nil, readAttachment: (() -> (Data, String, String)?)? = nil, notificationName: Notification.Name = UIPasteboard.changedNotification) {
        let accessDefaults = defaults ?? SharedStorage.defaults(allowShared: true)
        observation = ClipboardObservation(defaults: accessDefaults,
            owner: Bundle.main.bundleURL.pathExtension == "appex" ? .keyboard : .app)
        self.makeStore = makeStore ?? { ClipboardStore(url: SharedStorage.clipboardURL(allowShared: true)) }
        self.changeCount = changeCount ?? { UIPasteboard.general.changeCount }
        self.hasStrings = hasStrings ?? { UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs }
        // Type metadata does not read the clipboard payload or register a
        // permission attempt. An empty clipboard must not consume that attempt.
        self.hasContent = hasContent ?? (hasStrings ?? { !UIPasteboard.general.types.isEmpty })
        self.readText = readText ?? { UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString }
        if let readAttachment { self.readAttachment = readAttachment }
        else if readText != nil { self.readAttachment = { nil } }
        else { self.readAttachment = { Self.systemAttachment() } }
        self.notificationName = notificationName
    }
    func activate(settings: KeyboardSettings, allowed: Bool, retryPermission: Bool = false) {
        self.settings = settings
        guard allowed, settings.capturesClipboard else { stop(); return }
        active = true
        if retryPermission { observation.retry() }
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
        guard observation.shouldRead(changeCount: count, hasContent: hasContent()) else { return }
        // Remember denied/unavailable payloads too, so one copy cannot repeatedly prompt.
        observation.didAttempt(changeCount: count)
        if saveCurrentContent() { onCapture?() }
    }
    @discardableResult func captureManually() -> Bool {
        let saved = saveCurrentContent()
        observation.didAttempt(changeCount: changeCount())
        if saved { onCapture?() }; return saved
    }
    func checkAccess() -> AccessCheck {
        // This checks one explicit read, not the system's persistent Ask/Allow/
        // Deny setting, for which UIKit exposes no authorization-status API.
        guard hasContent() else { return .empty }
        return captureManually() ? .contentRead : .unavailable
    }
    func retryAfterPermissionChange() { observation.retry(); captureIfChanged() }
    func acceptText(_ text: String) {
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600); store.add(text)
        observation.didAttempt(changeCount: changeCount()); onCapture?()
    }
    func acceptAttachment(_ data: Data, typeIdentifier: String, name: String) {
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600)
        if store.addAttachment(data, typeIdentifier: typeIdentifier, name: name) { observation.didAttempt(changeCount: changeCount()); onCapture?() }
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
