import UIKit
import CoreFoundation

/// The group container is the primary route. A separate, local Keychain item
/// also carries appearance when a re-signing flow retains a common Keychain
/// group but removes App Groups. Neither route assumes it has permission.
final class AppearanceMirroredBackend: AppearanceSyncBackend {
    private let directory: URL?
    private let keychain: AppearanceSyncBackend
    init(groupRoot: URL?, keychain: AppearanceSyncBackend = AppearanceKeychainBackend()) {
        directory = groupRoot?.appendingPathComponent("Appearance-v1", isDirectory: true)
        self.keychain = keychain
    }
    private func timestamp(_ data: Data, account: String) -> Date? {
        if account == AppearanceSyncClient.settingsAccount {
            return try? AppearanceSyncClient.decode(data).get().updatedAt
        }
        return try? AppearanceSyncClient.decodeReceipt(data).get().updatedAt
    }
    func read(account: String) -> Result<AppearanceBackendRecord?, AppearanceSyncError> {
        guard account == AppearanceSyncClient.settingsAccount || account == AppearanceSyncClient.receiptAccount else { return .failure(.invalidPayload) }
        var candidates: [(AppearanceBackendRecord, Date)] = []
        if let directory {
            let file = directory.appendingPathComponent(account + ".json")
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size <= AppearanceSyncClient.maximumPayloadBytes,
               let data = try? Data(contentsOf: file), let date = timestamp(data, account: account) {
                candidates.append((AppearanceBackendRecord(data: data, accessGroup: "app-group"), date))
            }
        }
        let result = keychain.read(account: account)
        if case .success(let record?) = result, let date = timestamp(record.data, account: account) {
            candidates.append((record, date))
        }
        if let newest = candidates.max(by: { $0.1 < $1.1 }) { return .success(newest.0) }
        if directory != nil { return .success(nil) }
        return result
    }
    func write(_ data: Data, account: String) -> Result<String?, AppearanceSyncError> {
        guard (account == AppearanceSyncClient.settingsAccount || account == AppearanceSyncClient.receiptAccount),
              timestamp(data, account: account) != nil else { return .failure(.invalidPayload) }
        var fileSaved = false
        if let directory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(account + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                fileSaved = true
            } catch { /* The other authorized channel may still be available. */ }
        }
        let result = keychain.write(data, account: account)
        return fileSaved ? .success("app-group") : result
    }
}

@MainActor final class AppearanceSettingsLink {
    enum Role { case app, keyboard }
    enum Status: Equatable {
        case saved, waitingForKeyboard, receivedByKeyboard, unavailable
        var title: String {
            switch self {
            case .saved: return "外观已保存在本机"
            case .waitingForKeyboard: return "外观已保存，等待键盘接收"
            case .receivedByKeyboard: return "键盘已接收外观设置"
            case .unavailable: return "外观尚未同步，可在键盘内调整"
            }
        }
    }
    static let notification = "com.clearkeyboard.appearance.changed.v1"
    private let role: Role
    private let client: AppearanceSyncClient
    private var active = false
    private var generation = 0
    private var latest: AppearanceEnvelope?
    private var pendingEnvelope: AppearanceEnvelope?
    private var localSnapshot: AppearanceSnapshot?
    private var lastDelivered: UUID?
    private var receiptAttempt: UUID?
    var onReceive: ((AppearanceSnapshot) -> Void)?
    var onStatus: ((Status) -> Void)?
    var currentSettings: (() -> KeyboardSettings)?

    init(role: Role, client: AppearanceSyncClient) {
        self.role = role; self.client = client
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, pointer, _, _, _ in
            guard let pointer else { return }
            let link = Unmanaged<AppearanceSettingsLink>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor [weak link] in link?.refresh() }
        }, Self.notification as CFString, nil, .deliverImmediately)
    }
    static func production(role: Role) -> AppearanceSettingsLink {
        let root = (Bundle.main.object(forInfoDictionaryKey: "ClearAppGroup") as? String)
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        return AppearanceSettingsLink(role: role, client: AppearanceSyncClient(backend: AppearanceMirroredBackend(groupRoot: root)))
    }
    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
    func activate() {
        active = true; receiptAttempt = nil
        refresh()
    }
    func deactivate() { active = false; client.flush() }
    func publish(_ settings: KeyboardSettings) {
        let snapshot = AppearanceSnapshot(settings: settings)
        if localSnapshot == snapshot {
            if let pendingEnvelope { send(pendingEnvelope) }
            return
        }
        generation += 1; localSnapshot = snapshot
        let envelope = AppearanceEnvelope(snapshot: snapshot); latest = envelope; pendingEnvelope = envelope
        onStatus?(.saved)
        send(envelope)
    }
    private func send(_ envelope: AppearanceEnvelope) {
        client.publish(envelope) { [weak self] result in
            guard let self, self.latest?.revision == envelope.revision else { return }
            switch result {
            case .success:
                self.pendingEnvelope = nil
                self.onStatus?(.waitingForKeyboard)
                Self.postNotification()
                if self.role == .keyboard { self.confirm(envelope.revision) }
            case .failure(.superseded): break
            case .failure: self.onStatus?(.unavailable)
            }
        }
    }
    func refresh() {
        guard active else { return }
        if let pendingEnvelope { send(pendingEnvelope); return }
        let request = generation
        client.load { [weak self] result in
            guard let self, self.active, self.generation == request else { return }
            switch result {
            case .success(let read?):
                let envelope = read.envelope
                // An older channel must not overwrite a newer local edit.
                if let latest = self.latest, latest.updatedAt > envelope.updatedAt { return }
                self.latest = envelope; self.localSnapshot = envelope.snapshot
                let current = self.currentSettings.map { AppearanceSnapshot(settings: $0()) }
                if self.lastDelivered != envelope.revision || current != envelope.snapshot {
                    self.lastDelivered = envelope.revision
                    self.onReceive?(envelope.snapshot)
                }
                if self.role == .keyboard { self.confirm(envelope.revision) }
                else { self.checkReceipt(envelope.revision) }
            case .success(nil):
                if self.role == .app, let settings = self.currentSettings?(), self.latest == nil { self.publish(settings) }
            case .failure: self.onStatus?(.unavailable)
            }
        }
    }
    private func confirm(_ revision: UUID) {
        // Receipt means the production model has received this revision. It
        // does not assert a frame rate or a physical-device visual result.
        guard receiptAttempt != revision else { return }
        receiptAttempt = revision
        client.writeReceipt(revision: revision) { result in
            if case .success = result { Self.postNotification() }
        }
    }
    private func checkReceipt(_ revision: UUID) {
        client.readReceipt { [weak self] result in
            guard let self, self.latest?.revision == revision else { return }
            if case .success(let read?) = result, read.receipt.revision == revision { self.onStatus?(.receivedByKeyboard) }
            else { self.onStatus?(.waitingForKeyboard) }
        }
    }
    private static func postNotification() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(rawValue: notification as CFString), nil, nil, true)
    }
}
