import UIKit
import CoreFoundation
import UniformTypeIdentifiers

/// Observe copy notifications, with a foreground metadata check for remote-host
/// copies whose notification does not reach the keyboard extension. Payloads are
/// read only for a new clipboard revision or an explicit paste/save gesture.
@MainActor final class ClipboardCapture {
    enum AccessCheck { case empty, contentRead, reading, unavailable }
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
    private let systemAttachments: Bool
    private let asynchronousStorage: Bool
    private let io = DispatchQueue(label: "clear.clipboard.io", qos: .utility)
    private let notificationName: Notification.Name
    private let revisionCheckInterval: TimeInterval
    var onCapture: (() -> Void)?
    var onFailure: ((String) -> Void)?
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
        systemAttachments = readAttachment == nil && readText == nil
        asynchronousStorage = makeStore == nil
        if let readAttachment { self.readAttachment = readAttachment }
        else if readText != nil { self.readAttachment = { nil } }
        else { self.readAttachment = { nil } }
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
        if !systemAttachments { makeStore().prune(lifetime: settings.clipboardLifetimeHours * 3600) }
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
        if systemAttachments {
            let providers = UIPasteboard.general.itemProviders
            if !providers.isEmpty { ClipboardItemLoader.load(providers, revision: count, into: self) }
            else if hasStrings(), let text = readText() { acceptText(text, revision: count) }
            else { reportFailure(nil) }
            return
        }
        if saveCurrentContent() {
            if count == changeCount() { observation.didCapture(changeCount: count) }
            captured()

        }
    }
    @discardableResult func captureManually() -> Bool {
        let count = changeCount()
        if systemAttachments, hasContent() {
            let providers = UIPasteboard.general.itemProviders
            if !providers.isEmpty { ClipboardItemLoader.load(providers, revision: count, into: self) }
            else if hasStrings(), let text = readText() { acceptText(text, revision: count) }
            else { reportFailure(nil) }
            return true
        }
        let saved = saveCurrentContent()
        observation.didAttempt(changeCount: count)
        if saved {
            if count == changeCount() { observation.didCapture(changeCount: count) }
            captured()
        }; return saved
    }
    func checkAccess() -> AccessCheck {
        // This checks one explicit read, not the system's persistent Ask/Allow/
        // Deny setting, for which UIKit exposes no authorization-status API.
        guard hasContent() else { return .empty }
        if systemAttachments { _ = captureManually(); return .reading }
        return captureManually() ? .contentRead : .unavailable
    }
    func retryAfterPermissionChange() { observation.retry(); captureIfChanged() }
    func ignoreCurrentRevision() { observation.didCapture(changeCount: changeCount()) }
    func acceptText(_ text: String, revision: Int? = nil, completion: (() -> Void)? = nil) {
        save(revision: revision, completion: completion) { $0.add(text) }
    }
    func acceptAttachment(_ data: Data, typeIdentifier: String, name: String, revision: Int? = nil, completion: (() -> Void)? = nil) {
        save(revision: revision, completion: completion) { $0.addAttachment(data, typeIdentifier: typeIdentifier, name: name) }
    }
    private func save(revision: Int?, completion: (() -> Void)?, edit: @escaping (ClipboardStore) -> Bool) {
        let lifetime = settings.clipboardLifetimeHours * 3600
        let finish: (Bool, ClipboardStore.Failure?) -> Void = { [weak self] saved, error in
            if saved { self?.acceptRevision(revision); self?.captured() }
            else { self?.reportFailure(error) }
            completion?()
        }
        guard asynchronousStorage else {
            let store = makeStore(); _ = store.prune(lifetime: lifetime)
            let saved = edit(store); finish(saved, store.lastError); return
        }
        let url = SharedStorage.clipboardURL(allowShared: true)
        io.async {
            let store = ClipboardStore(url: url); _ = store.prune(lifetime: lifetime)
            let saved = edit(store), error = store.lastError
            DispatchQueue.main.async { finish(saved, error) }
        }
    }
    private func acceptRevision(_ revision: Int?) {
        guard let revision, revision == changeCount() else { return }
        observation.didAttempt(changeCount: revision); observation.didCapture(changeCount: revision)
    }
    func reportFailure(_ error: ClipboardStore.Failure?) {
        let text = error == .capacity ? "内容过大，未收录" : "未能保存，请重新复制后重试"
        onFailure?(text)
        NotificationCenter.default.post(name: Self.failure, object: text)
    }
    static let failure = Notification.Name("clear.clipboard.capture.failure")
    func clearHistory() { ignoreCurrentRevision(); save(revision: nil, completion: nil) { $0.clear() } }
    private func saveCurrentContent() -> Bool {
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600)
        if let (data, type, name) = readAttachment() {
            guard store.addAttachment(data, typeIdentifier: type, name: name), let saved = store.clips.first else { return false }
            return makeStore().clips.contains { $0.id == saved.id }
        }
        guard hasStrings(), let text = readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        store.add(text)
        return makeStore().clips.contains { $0.attachment == nil && $0.text == text }
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
