import UIKit
import CoreFoundation

/// The group container is the primary route. A separate, local Keychain item
/// also carries appearance when a re-signing flow retains a common Keychain
/// group but removes App Groups. Neither route assumes it has permission.
final class AppearanceMirroredBackend: AppearanceSyncBackend {
    private let groupRootProvider: () -> URL?
    private let additionalGroupRootsProvider: () -> [URL]
    private let keychain: AppearanceSyncBackend
    private let installationReady:Bool
    private(set) var diagnostics: AppearanceBackendDiagnostics
    init(groupRootProvider: @escaping () -> URL?, configuredGroup: String? = nil,
         keychain: AppearanceSyncBackend = AppearanceKeychainBackend(),
         additionalGroupRootsProvider: @escaping () -> [URL] = { [] },installationReady:Bool=true) {
        self.groupRootProvider = groupRootProvider
        self.additionalGroupRootsProvider = additionalGroupRootsProvider
        self.keychain = keychain
        self.installationReady=installationReady
        diagnostics = AppearanceBackendDiagnostics(configuredGroup: configuredGroup)
    }
    convenience init(groupRoot: URL?, keychain: AppearanceSyncBackend = AppearanceKeychainBackend()) {
        self.init(groupRootProvider: { groupRoot }, keychain: keychain)
    }
    private func directories() -> [URL] {
        let roots = [groupRootProvider()].compactMap { $0 } + additionalGroupRootsProvider()
        diagnostics.containerAvailable = !roots.isEmpty
        return Set(roots).map { $0.appendingPathComponent("Appearance-v1", isDirectory: true) }
    }
    private func copyKeychainDiagnostics() {
        let current = keychain.diagnostics
        diagnostics.keychainReadStatus = current.keychainReadStatus
        diagnostics.keychainWriteStatus = current.keychainWriteStatus
        diagnostics.keychainAccessGroup = current.keychainAccessGroup
    }
    private func timestamp(_ data: Data, account: String) -> Date? {
        if account == AppearanceSyncClient.settingsAccount {
            return try? AppearanceSyncClient.decode(data).get().updatedAt
        }
        return try? AppearanceSyncClient.decodeReceipt(data).get().updatedAt
    }
    func read(account: String) -> Result<AppearanceBackendRecord?, AppearanceSyncError> {
        guard installationReady else{return .success(nil)}
        guard account == AppearanceSyncClient.settingsAccount || account == AppearanceSyncClient.receiptAccount else { return .failure(.invalidPayload) }
        diagnostics.operation = "read-" + account; diagnostics.fileReadError = nil
        diagnostics.selectedChannel = nil
        var candidates: [(AppearanceBackendRecord, Date)] = []
        var fileFailure: AppearanceSyncError?
        let available = directories()
        for directory in available {
            let file = directory.appendingPathComponent(account + ".json")
            do {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if let size, size <= AppearanceSyncClient.maximumPayloadBytes {
                    let data = try Data(contentsOf: file)
                    if let date = timestamp(data, account: account) {
                        candidates.append((AppearanceBackendRecord(data: data, accessGroup: "app-group"), date))
                        diagnostics.fileRead = "ok"
                    } else {
                        diagnostics.fileRead = "invalid-payload"; fileFailure = .invalidPayload
                    }
                } else {
                    diagnostics.fileRead = "invalid-payload"; fileFailure = .invalidPayload
                }
            } catch {
                let error = error as NSError
                if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError) ||
                    (error.domain == NSPOSIXErrorDomain && error.code == 2) { diagnostics.fileRead = "missing" }
                else {
                    diagnostics.fileRead = "failed"; diagnostics.fileReadError = error.code
                    fileFailure = .file(error.code)
                }
            }
        }
        if available.isEmpty { diagnostics.fileRead = "container-unavailable" }
        let result = keychain.read(account: account)
        copyKeychainDiagnostics()
        if case .success(let record?) = result, let date = timestamp(record.data, account: account) {
            candidates.append((record, date))
        }
        if let newest = candidates.max(by: { $0.1 < $1.1 }) {
            diagnostics.selectedChannel = newest.0.accessGroup == "app-group" ? "app-group" : "keychain"
            if account == AppearanceSyncClient.settingsAccount {
                let envelopes = candidates.compactMap { try? AppearanceSyncClient.decode($0.0.data).get() }
                if let merged = AppearanceEnvelope.reconciling(envelopes), let data = try? AppearanceSyncClient.encode(merged).get() {
                    return .success(AppearanceBackendRecord(data: data, accessGroup: newest.0.accessGroup))
                }
            }
            return .success(newest.0)
        }
        if let fileFailure { return .failure(fileFailure) }
        return result
    }
    func write(_ data: Data, account: String) -> Result<String?, AppearanceSyncError> {
        guard installationReady else{return .failure(.file(NSFileReadNoPermissionError))}
        guard (account == AppearanceSyncClient.settingsAccount || account == AppearanceSyncClient.receiptAccount),
              timestamp(data, account: account) != nil else { return .failure(.invalidPayload) }
        diagnostics.operation = "write-" + account; diagnostics.fileWriteError = nil
        diagnostics.selectedChannel = nil
        var fileSaved = false
        var fileFailure: AppearanceSyncError?
        let available = directories()
        for directory in available {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(account + ".json")
                try SharedFileLock.perform(at: directory.appendingPathComponent("sync.lock")) {
                    var bytes = data
                    if account == AppearanceSyncClient.settingsAccount,
                       let incoming = try? AppearanceSyncClient.decode(data).get() {
                        let existing = (try? Data(contentsOf: file)).flatMap { try? AppearanceSyncClient.decode($0).get() }
                        let merged = existing.flatMap { AppearanceEnvelope.reconciling([$0, incoming]) } ?? incoming.initialFileSnapshot()
                        if merged != incoming { bytes = try AppearanceSyncClient.encode(merged).get() }
                    }
                    try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                fileSaved = true
                diagnostics.fileWrite = "ok"
            } catch {
                let error = error as NSError
                diagnostics.fileWrite = "failed"; diagnostics.fileWriteError = error.code
                fileFailure = .file(error.code)
            }
        }
        if available.isEmpty { diagnostics.fileWrite = "container-unavailable" }
        let result = keychain.write(data, account: account)
        copyKeychainDiagnostics()
        if fileSaved { diagnostics.selectedChannel = "app-group"; return .success("app-group") }
        if case .success = result { diagnostics.selectedChannel = "keychain"; return result }
        return fileFailure.map { .failure($0) } ?? result
    }
}

private enum AppearanceSyncNotification {
    static let name = "com.clearkeyboard.appearance.changed.v1"
    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(rawValue: name as CFString), nil, nil, true)
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
    static let notification = AppearanceSyncNotification.name
    private let role: Role
    private var client: AppearanceSyncClient
    private var installationIdentifier:String?
    private var installationPolicy:String?
    private var production=false
    private var installationReady=true
    private let receiverIdentity: AppearanceReceiverIdentity?
    private let expectedReceiver: AppearanceReceiverIdentity?
    private let includeInputPreferences: Bool
    private var active = false
    private var refreshTimer: Timer?
    private var generation = 0
    private var latest: AppearanceEnvelope?
    private var pendingEnvelope: AppearanceEnvelope?
    private var writingRevisions: Set<UUID> = []
    private var localSnapshot: AppearanceSnapshot?
    private var lastDelivered: UUID?
    private var receiptAttempt: UUID?
    var onReceive: ((AppearanceSnapshot) -> Void)?
    var onStatus: ((Status) -> Void)?
    var currentSettings: (() -> KeyboardSettings)?
    private(set) var diagnostics: AppearanceSyncDiagnostics {
        didSet { if diagnostics != oldValue { onDiagnostics?(diagnostics) } }
    }
    var onDiagnostics: ((AppearanceSyncDiagnostics) -> Void)? {
        didSet { onDiagnostics?(diagnostics) }
    }

    init(role: Role, client: AppearanceSyncClient, receiverIdentity: AppearanceReceiverIdentity? = nil,
         expectedReceiver: AppearanceReceiverIdentity? = nil, includeInputPreferences: Bool = false) {
        self.role = role; self.client = client
        self.receiverIdentity = receiverIdentity; self.expectedReceiver = expectedReceiver
        self.includeInputPreferences = includeInputPreferences
        diagnostics = AppearanceSyncDiagnostics(role: role == .app ? "app" : "keyboard",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            receiver: receiverIdentity, expectedReceiver: expectedReceiver)
        observeClientDiagnostics()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, pointer, _, _, _ in
            guard let pointer else { return }
            let link = Unmanaged<AppearanceSettingsLink>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor [weak link] in link?.reconcileInstallationAndRefresh() }
        }, Self.notification as CFString, nil, .deliverImmediately)
    }
    static func production(role: Role) -> AppearanceSettingsLink {
        let snapshot=InstallationLifecycle.prepare(refresh:true)
        let link=AppearanceSettingsLink(role: role, client: productionClient(snapshot),
            receiverIdentity: role == .keyboard ? .keyboardBundle(.main) : nil,
            expectedReceiver: role == .app ? .embeddedKeyboard(in: .main) : nil, includeInputPreferences: true)
        link.production=true;link.installationIdentifier=snapshot.identifier;link.installationPolicy=InstallationLifecycle.policy(snapshot);link.installationReady=snapshot.ready
        link.observeClientDiagnostics();return link
    }
    private static func productionClient(_ snapshot:InstallationLifecycle.Snapshot)->AppearanceSyncClient {
        let base="com.clearkeyboard.appearance.sync.v1"
        let groups=InstallationLifecycle.rawGroups()
        if snapshot.ready,snapshot.legacy || !(snapshot.priorIdentifiers?.isEmpty ?? true) {
            for group in groups {
                guard let backing=UserDefaults(suiteName:group.identifier) else{continue}
                let preferences=InstallationLifecycle.scopedDefaults(backing,domain:group.identifier)
                let marker="clear.installation.appearance-file-import."+InstallationLifecycle.policy(snapshot)
                guard !preferences.bool(forKey:marker) else{continue}
                var sources=InstallationLifecycle.priorRoots(group.root,snapshot:snapshot).map{$0.appendingPathComponent("Appearance-v1/appearance.json")}
                if snapshot.legacy {sources.append(group.root.appendingPathComponent("Appearance-v1/appearance.json"))}
                let directory=InstallationLifecycle.sharedRoot(group.root,snapshot:snapshot).appendingPathComponent("Appearance-v1")
                let destination=directory.appendingPathComponent("appearance.json")
                do {
                    try SharedFileLock.perform(at:directory.appendingPathComponent("sync.lock")) {
                        var envelopes:[AppearanceEnvelope]=[]
                        // Re-read destination under the normal writer's lock.
                        for source in sources+[destination] where FileManager.default.fileExists(atPath:source.path) {
                            let data=try Data(contentsOf:source)
                            guard data.count<=AppearanceSyncClient.maximumPayloadBytes else{continue}
                            envelopes.append(try AppearanceSyncClient.decode(data).get())
                        }
                        if let merged=AppearanceEnvelope.reconciling(envelopes) {
                            let data=try AppearanceSyncClient.encode(merged).get()
                            try data.write(to:destination,options:.atomic)
                        }
                    }
                    // Preferences may enter lifecycle migration; never hold the
                    // filesystem sync lock while publishing this marker.
                    preferences.set(true,forKey:marker)
                } catch { /* Retry only trusted upgrade migration, never fresh recovery. */ }
            }
        }
        // Backends capture this namespace. A queued old write cannot cross into
        // a replacement installation when the lifecycle is reconciled later.
        let keychain=AppearanceKeychainBackend(service:InstallationLifecycle.service(base,snapshot:snapshot),
            installationScoped:false,legacyService:snapshot.ready && snapshot.legacy ? base:nil,
            previousServices:InstallationLifecycle.priorServices(base,snapshot:snapshot))
        let backend=AppearanceMirroredBackend(groupRootProvider:{
            InstallationLifecycle.rawGroups().first.map{InstallationLifecycle.sharedRoot($0.root,snapshot:snapshot)}
        },configuredGroup:Bundle.main.object(forInfoDictionaryKey:"ClearAppGroup") as? String,keychain:keychain,
        additionalGroupRootsProvider:{InstallationLifecycle.rawGroups().dropFirst().map{InstallationLifecycle.sharedRoot($0.root,snapshot:snapshot)}},installationReady:snapshot.ready)
        return AppearanceSyncClient(backend:backend)
    }
    private func observeClientDiagnostics() {
        let namespace=installationIdentifier
        client.observeDiagnostics { [weak self] backend in
            guard let self,self.installationIdentifier==namespace else{return}
            self.diagnostics.backend=backend
        }
    }
    private func reconcileInstallation() {
        guard production else{return}
        let snapshot=InstallationLifecycle.prepare(refresh:true)
        let policy=InstallationLifecycle.policy(snapshot)
        guard installationIdentifier != snapshot.identifier || installationReady != snapshot.ready || installationPolicy != policy else{return}
        installationIdentifier=snapshot.identifier;installationPolicy=policy;installationReady=snapshot.ready
        client=Self.productionClient(snapshot);observeClientDiagnostics()
        generation += 1;latest=nil;pendingEnvelope=nil;localSnapshot=nil
        writingRevisions.removeAll();lastDelivered=nil;receiptAttempt=nil
        if snapshot.ready {
            let preferences=SharedStorage.defaults(allowShared:role == .app || diagnostics.fullAccess == true)
            let clean=SettingsStore(defaults:preferences).load()
            onReceive?(AppearanceSnapshot(settings:clean,includeInputPreferences:includeInputPreferences))
        }
    }
    private func reconcileInstallationAndRefresh() {
        reconcileInstallation();refresh()
    }
    deinit {
        refreshTimer?.invalidate()
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
    func updateFullAccess(_ value: Bool) {
        guard role == .keyboard else { return }
        diagnostics.fullAccess = value
    }
    func activate() {
        reconcileInstallation()
        guard !active else { refresh(); return }
        active = true; receiptAttempt = nil
        // Notifications are hints. Reconcile while visible as well, so a write
        // completed during suspension does not require killing the keyboard.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer = timer; RunLoop.main.add(timer, forMode: .default)
        diagnostics.active = true; diagnostics.event = "activated"
        refresh()
    }
    var hasPendingWrite: Bool { pendingEnvelope != nil || !writingRevisions.isEmpty }
    func deactivate(completion: (() -> Void)? = nil) {
        active = false; refreshTimer?.invalidate(); refreshTimer = nil
        diagnostics.active = false; diagnostics.event = "deactivated"
        client.flush(completion: completion)
    }
    func publish(_ settings: KeyboardSettings, previous: KeyboardSettings? = nil) {
        let snapshot = AppearanceSnapshot(settings: settings, includeInputPreferences: includeInputPreferences)
        if localSnapshot == snapshot {
            if let pendingEnvelope { send(pendingEnvelope) }
            return
        }
        let bootstrap = previous == nil && localSnapshot == nil && latest == nil
        let old = previous.map { AppearanceSnapshot(settings: $0, includeInputPreferences: includeInputPreferences) } ?? localSnapshot
        let changed = old.map { snapshot.changedFields(from: $0) } ?? Array(AppearanceSnapshot.fieldNames)
        var fields = changed
        var fieldDates = pendingEnvelope?.fieldDates ?? [:]
        if let pending = pendingEnvelope {
            for field in pending.changedFields ?? Array(AppearanceSnapshot.fieldNames) where fieldDates[field] == nil { fieldDates[field] = pending.updatedAt }
        }
        if let pending = pendingEnvelope { fields = Array(Set(fields).union(pending.changedFields ?? Array(AppearanceSnapshot.fieldNames))) }
        generation += 1; localSnapshot = snapshot
        let date = max(Date(), (latest?.updatedAt ?? .distantPast).addingTimeInterval(0.0001))
        for field in changed { fieldDates[field] = bootstrap ? .distantPast : date }
        let envelope = AppearanceEnvelope(snapshot: snapshot, updatedAt: date, changedFields: fields, fieldDates: fieldDates); latest = envelope; pendingEnvelope = envelope
        diagnostics.latestRevision = envelope.revision; diagnostics.event = "local-edit"
        diagnostics.rejection = nil
        onStatus?(.saved)
        send(envelope)
    }
    private func send(_ envelope: AppearanceEnvelope) {
        // Our Darwin notification can arrive before the main completion that
        // clears pendingEnvelope. Do not re-save an already queued revision.
        guard writingRevisions.insert(envelope.revision).inserted else { return }
        client.publish(envelope, didPersist: AppearanceSyncNotification.post) { [weak self] result in
            guard let self else { return }
            self.writingRevisions.remove(envelope.revision)
            guard self.latest?.revision == envelope.revision else { return }
            switch result {
            case .success:
                self.pendingEnvelope = nil
                self.diagnostics.event = "persisted"
                self.onStatus?(.waitingForKeyboard)
                if self.role == .keyboard { self.confirm(envelope) }
                // A notification is only a hint and may have arrived while
                // this revision was still pending. Re-read after clearing it
                // so an early receiver reply or newer remote edit is not lost.
                if self.active { self.refresh() }
            case .failure(.superseded): break
            case .failure:
                self.diagnostics.event = "save-failed"; self.onStatus?(.unavailable)
            }
        }
    }
    func refresh() {
        if production,!installationReady {reconcileInstallation()}
        guard active else { return }
        if let pendingEnvelope { send(pendingEnvelope); return }
        let request = generation
        client.load { [weak self] result in
            guard let self, self.active, self.generation == request else { return }
            switch result {
            case .success(let read?):
                let envelope = read.envelope
                // An older channel must not overwrite a newer local edit.
                if let latest = self.latest, latest.updatedAt > envelope.updatedAt {
                    self.diagnostics.event = "older-read-ignored"; return
                }
                self.latest = envelope; self.localSnapshot = envelope.snapshot
                self.diagnostics.latestRevision = envelope.revision; self.diagnostics.event = "read"
                let applied = self.currentSettings.map { envelope.snapshot.isApplied(to: $0()) } ?? false
                if self.lastDelivered != envelope.revision || !applied {
                    self.lastDelivered = envelope.revision
                    self.onReceive?(envelope.snapshot)
                }
                if self.role == .keyboard { self.confirm(envelope) }
                else { self.checkReceipt(envelope) }
            case .success(nil):
                if self.role == .app, let settings = self.currentSettings?(), self.latest == nil { self.publish(settings) }
                if self.role == .keyboard { self.diagnostics.event = "no-shared-appearance" }
            case .failure:
                self.diagnostics.event = "read-failed"; self.onStatus?(.unavailable)
            }
        }
    }
    private func confirm(_ envelope: AppearanceEnvelope) {
        guard diagnostics.fullAccess != false else {
            diagnostics.rejection = "full-access-not-available"; return
        }
        guard let receiverIdentity, receiverIdentity.isValid else {
            diagnostics.rejection = "receiver-is-not-a-keyboard-extension"; return
        }
        guard let currentSettings, envelope.snapshot.isApplied(to: currentSettings()) else {
            diagnostics.rejection = "model-snapshot-not-applied"; return
        }
        // The identity is created from the real .appex in production. A model
        // receipt proves exact settings application, not a physical screen frame.
        diagnostics.appliedRevision = envelope.revision; diagnostics.rejection = nil
        guard receiptAttempt != envelope.revision else { return }
        receiptAttempt = envelope.revision
        client.writeReceipt(revision: envelope.revision, snapshot: envelope.snapshot, receiver: receiverIdentity,
                            didPersist: AppearanceSyncNotification.post) { [weak self] result in
            guard let self, self.latest?.revision == envelope.revision else { return }
            switch result {
            case .success:
                self.diagnostics.receiptRevision = envelope.revision; self.diagnostics.event = "receiver-confirmed"
            case .failure:
                if self.receiptAttempt == envelope.revision { self.receiptAttempt = nil }
                self.diagnostics.event = "receipt-write-failed"; self.onStatus?(.unavailable)
            }
        }
    }
    private func checkReceipt(_ envelope: AppearanceEnvelope) {
        client.readReceipt { [weak self] result in
            guard let self, self.latest?.revision == envelope.revision else { return }
            switch result {
            case .success(let read?):
                self.diagnostics.receiptRevision = read.receipt.revision
                guard read.receipt.revision == envelope.revision,
                      read.receipt.snapshot == envelope.snapshot,
                      let expected = self.expectedReceiver, read.receipt.receiver == expected else {
                    self.diagnostics.rejection = "receipt-identity-revision-or-snapshot-mismatch"
                    self.onStatus?(.waitingForKeyboard); return
                }
                self.diagnostics.event = "keyboard-applied-exact-revision"; self.diagnostics.rejection = nil
                self.onStatus?(.receivedByKeyboard)
            case .success(nil): self.onStatus?(.waitingForKeyboard)
            case .failure:
                self.diagnostics.event = "receipt-read-failed"; self.onStatus?(.unavailable)
            }
        }
    }
}
