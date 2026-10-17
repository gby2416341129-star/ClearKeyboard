import UIKit

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
    private let notificationName: Notification.Name
    private static let observedKey = "clear.clipboard.observedChangeCount.v1"
    var onCapture: (() -> Void)?

    init(defaults: UserDefaults? = nil, makeStore: (() -> ClipboardStore)? = nil,
         changeCount: (() -> Int)? = nil, hasStrings: (() -> Bool)? = nil,
         readText: (() -> String?)? = nil, notificationName: Notification.Name = UIPasteboard.changedNotification) {
        self.defaults = defaults ?? SharedStorage.defaults(allowShared: true)
        self.makeStore = makeStore ?? { ClipboardStore(url: SharedStorage.clipboardURL(allowShared: true)) }
        self.changeCount = changeCount ?? { UIPasteboard.general.changeCount }
        self.hasStrings = hasStrings ?? { UIPasteboard.general.hasStrings }
        self.readText = readText ?? { UIPasteboard.general.string }
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
        guard hasStrings(), let text = readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600); store.add(text)
        onCapture?()
    }
    @discardableResult func captureManually() -> Bool {
        guard let text = readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let store = makeStore(); store.prune(lifetime: settings.clipboardLifetimeHours * 3600); store.add(text)
        defaults.set(changeCount(), forKey: Self.observedKey); onCapture?(); return true
    }
    func stop() {
        active = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
