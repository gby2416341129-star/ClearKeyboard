import UIKit
import CoreFoundation
import UniformTypeIdentifiers

/// Observe copy notifications, with a foreground metadata check for remote-host
/// copies whose notification does not reach the keyboard extension. Payloads are
/// read only for a new clipboard revision or an explicit paste/save gesture.
@MainActor final class ClipboardCapture {
    enum AccessCheck { case empty, contentRead, unavailable }
    private var observer: NSObjectProtocol?
    private var revisionTimer: Timer?
    private var active = false
    private var historyIDs: [UUID] = []
    private var settings = KeyboardSettings()
    private let observation: ClipboardObservation
    private let makeStore: () -> ClipboardStore
    private let changeCount: () -> Int
    private let hasStrings: () -> Bool
    private let hasContent: () -> Bool
    private let readText: () -> String?
    private let readAttachment: () -> (Data, String, String)?
    private let notificationName: Notification.Name
    private let revisionCheckInterval: TimeInterval
    var onCapture: (() -> Void)?
    static let historyChanged = "com.clearkeyboard.clipboard.history.changed.v1"
    private func captured() {
        historyIDs = makeStore().clips.map(\.id)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: Self.historyChanged as CFString), nil, nil, true)
        onCapture?()
    }

    init(defaults: UserDefaults? = nil, makeStore: (() -> ClipboardStore)? = nil,
         changeCount: (() -> Int)? = nil, hasStrings: (() -> Bool)? = nil, hasContent: (() -> Bool)? = nil,
         readText: (() -> String?)? = nil, readAttachment: (() -> (Data, String, String)?)? = nil, notificationName: Notification.Name = UIPasteboard.changedNotification,
         revisionCheckInterval: TimeInterval = 0.75) {
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
        self.revisionCheckInterval = revisionCheckInterval.isFinite && revisionCheckInterval > 0 ? revisionCheckInterval : 0.75
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, pointer, _, _, _ in
            guard let pointer else { return }
            let capture = Unmanaged<ClipboardCapture>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor [weak capture] in
                guard let capture, capture.active else { return }
                let ids = capture.makeStore().clips.map(\.id)
                guard ids != capture.historyIDs else { return }
                capture.historyIDs = ids; capture.onCapture?()
            }
        }, Self.historyChanged as CFString, nil, .deliverImmediately)
    }
    func activate(settings: KeyboardSettings, allowed: Bool, retryPermission: Bool = false) {
        self.settings = settings
        guard allowed, settings.capturesClipboard else { stop(); return }
        let newSession = !active
        active = true
        if retryPermission || newSession { observation.retry() }
        makeStore().prune(lifetime: settings.clipboardLifetimeHours * 3600)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.captureIfChanged() }
            }
        }
        if revisionTimer == nil {
            let timer = Timer(timeInterval: revisionCheckInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.captureIfChanged() }
            }
            revisionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        captureIfChanged()
    }
    func captureIfChanged() {
        guard active else { return }
        let count = changeCount()
        guard observation.shouldRead(changeCount: count, hasContent: hasContent()) else { return }
        // Suppress repeated attempts in this visible session. A failed read
        // must not permanently suppress the same revision after reopening.
        observation.didAttempt(changeCount: count)
        if saveCurrentContent() { captured() }
    }
    @discardableResult func captureManually() -> Bool {
        let saved = saveCurrentContent()
        observation.didAttempt(changeCount: changeCount())
        if saved { captured() }; return saved
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
        guard makeStore().clips.contains(where: { $0.attachment == nil && $0.text == String(text.prefix(2_000)) }) else { return }
        observation.didAttempt(changeCount: changeCount()); captured()
    }
    func acceptAttachment(_ data: Data, typeIdentifier: String, name: String) {
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600)
        if store.addAttachment(data, typeIdentifier: typeIdentifier, name: name),
           let saved = store.clips.first, makeStore().clips.contains(where: { $0.id == saved.id }) {
            observation.didAttempt(changeCount: changeCount()); captured()
        }
    }
    private func saveCurrentContent() -> Bool {
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600)
        if let (data, type, name) = readAttachment() {
            guard store.addAttachment(data, typeIdentifier: type, name: name), let saved = store.clips.first else { return false }
            return makeStore().clips.contains { $0.id == saved.id }
        }
        guard hasStrings(), let text = readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        store.add(text)
        return makeStore().clips.contains { $0.attachment == nil && $0.text == String(text.prefix(2_000)) }
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
        revisionTimer?.invalidate(); revisionTimer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
    deinit {
        revisionTimer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) }
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}
