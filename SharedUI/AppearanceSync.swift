import Foundation
import Security

/// Presentation and keyboard tool preferences share a revision. Typed text,
/// clipboard payloads and learned words never enter this channel.
struct AppearanceSnapshot: Codable, Equatable {
    let accent: Accent
    let customAccentHex: String?
    let keyGlassStrength: Double?
    let keyColorHex: String?
    let candidateColorHex: String?
    let candidateTextSize: CandidateTextSize?
    let keyHeight: Double?
    let vibrationEnabled: Bool?
    let vibrationIntensity: Double?
    let vibrationMode: VibrationMode?
    let hand: HandMode?
    let oneHandWidth: Double?
    let toolbar: [ToolbarTool]?
    let localPinyinComposition: Bool?
    let automaticClipboard: Bool?
    let clipboardLifetimeHours: Double?
    let language: InputLanguage?
    let fuzzyPairs: Set<String>?
    let predictions: Bool?
    let learnChoices: Bool?
    let autoCapitalization: Bool?

    init(settings: KeyboardSettings, includeInputPreferences: Bool = false) {
        var value = settings; value.sanitize()
        accent = value.accent; customAccentHex = value.customAccentHex
        keyGlassStrength = value.keyGlassStrength
        keyColorHex = value.keyColorHex
        candidateColorHex = value.candidateColorHex; candidateTextSize = value.candidateTextSize
        keyHeight = value.keyHeight
        vibrationEnabled = value.usesVibration; vibrationIntensity = value.resolvedVibrationIntensity
        vibrationMode = value.resolvedVibrationMode
        hand = value.hand; oneHandWidth = value.oneHandFraction; toolbar = value.toolbar
        localPinyinComposition = value.localPinyinComposition == true
        automaticClipboard = value.capturesClipboard; clipboardLifetimeHours = value.clipboardLifetimeHours
        language = includeInputPreferences ? value.language : nil
        fuzzyPairs = includeInputPreferences ? value.fuzzyPairs : nil
        predictions = includeInputPreferences ? value.predictions : nil
        learnChoices = includeInputPreferences ? value.learnChoices : nil
        autoCapitalization = includeInputPreferences ? value.autoCapitalization : nil
    }
    func applying(to settings: KeyboardSettings) -> KeyboardSettings {
        var value = settings
        value.accent = accent; value.customAccentHex = customAccentHex
        value.keyGlassStrength = keyGlassStrength
        value.keyColorHex = keyColorHex
        value.candidateColorHex = candidateColorHex; value.candidateTextSize = candidateTextSize
        if let keyHeight { value.keyHeight = keyHeight }
        if let vibrationEnabled { value.vibrationEnabled = vibrationEnabled }
        if let vibrationIntensity { value.vibrationIntensity = vibrationIntensity }
        if let vibrationMode { value.vibrationMode = vibrationMode }
        if let hand { value.hand = hand }
        if let oneHandWidth { value.oneHandWidth = oneHandWidth }
        if let toolbar { value.toolbar = toolbar }
        if let localPinyinComposition { value.localPinyinComposition = localPinyinComposition }
        if let automaticClipboard { value.automaticClipboard = automaticClipboard }
        if let clipboardLifetimeHours { value.clipboardLifetimeHours = clipboardLifetimeHours }
        if let language { value.language = language }
        if let fuzzyPairs { value.fuzzyPairs = fuzzyPairs }
        if let predictions { value.predictions = predictions }
        if let learnChoices { value.learnChoices = learnChoices }
        if let autoCapitalization { value.autoCapitalization = autoCapitalization }
        // The snapshot is normalized on creation and validated on decode.
        // Do not run unrelated language/learning migrations while applying it.
        return value
    }
    /// Older snapshots did not carry height. Compare the fields they requested
    /// after applying them, so an absent height preserves the receiver's layout.
    func isApplied(to settings: KeyboardSettings) -> Bool { applying(to: settings) == settings }
    static let fieldNames = Set(Mirror(reflecting: AppearanceSnapshot(settings: KeyboardSettings(), includeInputPreferences: true)).children.compactMap(\.label))
    var fieldValues: [String: Any] {
        guard let data = try? JSONEncoder().encode(self), let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }
    func changedFields(from old: AppearanceSnapshot) -> [String] {
        let left = fieldValues, right = old.fieldValues
        return Self.fieldNames.filter { key in
            !NSDictionary(dictionary: ["value": left[key] ?? NSNull()]).isEqual(to: ["value": right[key] ?? NSNull()])
        }.sorted()
    }
    var isValid: Bool {
        if let fuzzyPairs, !fuzzyPairs.isSubset(of: Set(FuzzyPinyin.availablePairs)) { return false }
        if let oneHandWidth, !oneHandWidth.isFinite || !(0.68...0.88).contains(oneHandWidth) { return false }
        if let toolbar, toolbar.count > ToolbarTool.allCases.count || Set(toolbar).count != toolbar.count { return false }
        if let clipboardLifetimeHours, !clipboardLifetimeHours.isFinite || !(clipboardLifetimeHours == 0 || (0.25...8760).contains(clipboardLifetimeHours)) { return false }
        let strengths = [keyGlassStrength, vibrationIntensity].compactMap { $0 }
        guard strengths.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        if let keyHeight, !keyHeight.isFinite || !(44...58).contains(keyHeight) { return false }
        for color in [customAccentHex, keyColorHex, candidateColorHex].compactMap({ $0 }) {
            guard RGBColor(hex: color)?.hex == color else { return false }
        }
        return true
    }
}

struct AppearanceEnvelope: Codable, Equatable {
    static let baselineDate = Date.distantPast.addingTimeInterval(1)
    let schema: Int
    let revision: UUID
    let updatedAt: Date
    let snapshot: AppearanceSnapshot
    let changedFields: [String]?
    let fieldDates: [String: Date]?
    init(snapshot: AppearanceSnapshot, revision: UUID = UUID(), updatedAt: Date = Date(), changedFields: [String]? = nil, fieldDates: [String: Date]? = nil) {
        schema = 1; self.revision = revision; self.updatedAt = updatedAt; self.snapshot = snapshot
        self.changedFields = changedFields; self.fieldDates = fieldDates
    }
    var hasValidFields: Bool {
        (changedFields.map { Set($0).isSubset(of: AppearanceSnapshot.fieldNames) } ?? true) &&
            (fieldDates?.allSatisfy { AppearanceSnapshot.fieldNames.contains($0.key) && $0.value.timeIntervalSince1970.isFinite } ?? true)
    }
    func initialBaseline() -> AppearanceEnvelope {
        AppearanceEnvelope(snapshot: snapshot, revision: revision, updatedAt: Self.baselineDate,
            fieldDates: Dictionary(uniqueKeysWithValues: AppearanceSnapshot.fieldNames.map { ($0, Self.baselineDate) }))
    }
    func initialFileSnapshot() -> AppearanceEnvelope {
        guard let changedFields else { return self }
        var dates = initialBaseline().fieldDates!
        for field in changedFields { dates[field] = max(Self.baselineDate, fieldDates?[field] ?? updatedAt) }
        return AppearanceEnvelope(snapshot: snapshot, revision: revision, updatedAt: updatedAt, fieldDates: dates)
    }
    static func reconciling(_ envelopes: [AppearanceEnvelope]) -> AppearanceEnvelope? {
        if let first = envelopes.first, envelopes.allSatisfy({ $0 == first }) { return first }
        if envelopes.count == 1, envelopes[0].changedFields == nil { return envelopes[0] }
        guard let latest = envelopes.max(by: {
            $0.updatedAt == $1.updatedAt ? $0.revision.uuidString < $1.revision.uuidString : $0.updatedAt < $1.updatedAt
        }) else { return nil }
        let baseline = envelopes.min { $0.updatedAt < $1.updatedAt }!.snapshot
        var values = baseline.fieldValues
        var dates = Dictionary(uniqueKeysWithValues: AppearanceSnapshot.fieldNames.map { ($0, Date.distantPast) })
        var revisions: [String: String] = [:]
        for envelope in envelopes {
            let incoming = envelope.snapshot.fieldValues
            for key in envelope.changedFields ?? Array(AppearanceSnapshot.fieldNames) {
                let date = envelope.fieldDates?[key] ?? envelope.updatedAt
                if let old = dates[key], old > date || (old == date && (revisions[key] ?? "") >= envelope.revision.uuidString) { continue }
                values[key] = incoming[key]
                dates[key] = date; revisions[key] = envelope.revision.uuidString
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let snapshot = try? JSONDecoder().decode(AppearanceSnapshot.self, from: data) else { return nil }
        return AppearanceEnvelope(snapshot: snapshot, revision: latest.revision, updatedAt: latest.updatedAt, fieldDates: dates)
    }
}

struct AppearanceReceipt: Codable, Equatable {
    let schema: Int
    let revision: UUID
    let updatedAt: Date
    let snapshot: AppearanceSnapshot
    let receiver: AppearanceReceiverIdentity
    init(revision: UUID, snapshot: AppearanceSnapshot, receiver: AppearanceReceiverIdentity, updatedAt: Date = Date()) {
        schema = 2; self.revision = revision; self.snapshot = snapshot
        self.receiver = receiver; self.updatedAt = updatedAt
    }
}

struct AppearanceReceiverIdentity: Codable, Equatable {
    let bundleIdentifier: String
    let version: String
    let build: String
    let extensionPoint: String
    var isValid: Bool {
        !bundleIdentifier.isEmpty && !version.isEmpty && !build.isEmpty && extensionPoint == "com.apple.keyboard-service"
    }
    static func keyboardBundle(_ bundle: Bundle) -> AppearanceReceiverIdentity? {
        guard bundle.bundleURL.pathExtension == "appex",
              let identifier = bundle.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let configuration = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
              let point = configuration["NSExtensionPointIdentifier"] as? String else { return nil }
        let value = Self(bundleIdentifier: identifier, version: version, build: build, extensionPoint: point)
        return value.isValid ? value : nil
    }
    static func embeddedKeyboard(in bundle: Bundle) -> AppearanceReceiverIdentity? {
        guard let plugins = bundle.builtInPlugInsURL,
              let children = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
        let identities = children.compactMap { Bundle(url: $0) }.compactMap(Self.keyboardBundle)
        return identities.count == 1 ? identities.first : nil
    }
}

/// Capability and operation results only: no typed text, learned words,
/// clipboard contents, container paths or complete settings payloads.
struct AppearanceBackendDiagnostics: Codable, Equatable {
    var configuredGroup: String?
    var containerAvailable = false
    var fileRead = "not-attempted"
    var fileReadError: Int?
    var fileWrite = "not-attempted"
    var fileWriteError: Int?
    var keychainReadStatus: OSStatus?
    var keychainWriteStatus: OSStatus?
    var keychainAccessGroup: String?
    var selectedChannel: String?
    var operation = "idle"
}

struct AppearanceSyncDiagnostics: Codable, Equatable {
    var role = "unknown"
    var bundleIdentifier = "unknown"
    var version = "unknown"
    var build = "unknown"
    var active = false
    var fullAccess: Bool?
    var event = "created"
    var latestRevision: UUID?
    var appliedRevision: UUID?
    var receiptRevision: UUID?
    var receiver: AppearanceReceiverIdentity?
    var expectedReceiver: AppearanceReceiverIdentity?
    var rejection: String?
    var backend = AppearanceBackendDiagnostics()
}

enum AppearanceSyncError: Error, Equatable {
    case keychain(OSStatus)
    case file(Int)
    case invalidPayload
    case unsupportedSchema(Int)
    case superseded
}

struct AppearanceBackendRecord {
    let data: Data
    let accessGroup: String?
}

protocol AppearanceSyncBackend: AnyObject {
    var diagnostics: AppearanceBackendDiagnostics { get }
    func read(account: String) -> Result<AppearanceBackendRecord?, AppearanceSyncError>
    func write(_ data: Data, account: String) -> Result<String?, AppearanceSyncError>
}
extension AppearanceSyncBackend {
    var diagnostics: AppearanceBackendDiagnostics { AppearanceBackendDiagnostics() }
}

/// Uses only the process's authorized keychain groups. Omitting an explicit
/// group lets Security choose its real default; it never fabricates permissions.
/// A successful local write is not evidence that the keyboard can read it.
final class AppearanceKeychainBackend: AppearanceSyncBackend {
    private var patchWrites = 0
    let service: String
    private let configuredAccessGroup: String?
    private lazy var sharedAccessGroup: String? = {
        guard let configuredAccessGroup else { return nil }
        // An unsigned build has no AppIdentifierPrefix at Info.plist expansion.
        // Ask Security for this installation's real prefix after re-signing;
        // never hard-code a team or assume an entitlement has been granted.
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".group-probe", kSecAttrAccount as String: "local-prefix",
            kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(probe as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = probe; add[kSecValueData as String] = Data([0])
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".") else { return configuredAccessGroup }
        let prefix = String(group[...dot])
        return configuredAccessGroup.hasPrefix(prefix) ? configuredAccessGroup : prefix + configuredAccessGroup
    }()
    private(set) var diagnostics = AppearanceBackendDiagnostics()
    init(service: String = "com.clearkeyboard.appearance.sync.v1", accessGroup: String? = Bundle.main.object(forInfoDictionaryKey: "ClearSharedKeychainGroup") as? String) {
        self.service = service
        configuredAccessGroup = accessGroup.flatMap { !$0.isEmpty && !$0.contains("$(") ? $0 : nil }
    }
    private func query(_ account: String) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
        if let sharedAccessGroup { result[kSecAttrAccessGroup as String] = sharedAccessGroup }
        return result
    }
    func read(account: String) -> Result<AppearanceBackendRecord?, AppearanceSyncError> {
        // Re-signing may move the shared item to another granted group. Search
        // all groups Security permits, rather than pinning reads to the old name.
        var query = query(account); query.removeValue(forKey: kSecAttrAccessGroup as String)
        if account == AppearanceSyncClient.settingsAccount { query.removeValue(forKey: kSecAttrAccount as String) }
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        diagnostics.operation = "keychain-read"; diagnostics.keychainReadStatus = status
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess else { return .failure(.keychain(status)) }
        guard let entries = result as? [[String: Any]] else { return .failure(.invalidPayload) }
        if account == AppearanceSyncClient.settingsAccount {
            let records = entries.compactMap { attributes -> (AppearanceEnvelope, String?)? in
                guard let name = attributes[kSecAttrAccount as String] as? String,
                      name == account || name.hasPrefix(account + ".patch."),
                      let data = attributes[kSecValueData as String] as? Data,
                      let envelope = try? AppearanceSyncClient.decode(data).get() else { return nil }
                return (envelope, attributes[kSecAttrAccessGroup as String] as? String)
            }
            guard let merged = AppearanceEnvelope.reconciling(records.map(\.0)),
                  let data = try? AppearanceSyncClient.encode(merged).get() else {
                let attempted = entries.contains { row in
                    guard let name = row[kSecAttrAccount as String] as? String else { return false }
                    return name == account || name.hasPrefix(account + ".patch.")
                }
                return attempted ? .failure(.invalidPayload) : .success(nil)
            }
            let group = records.first { $0.0.revision == merged.revision }?.1
            diagnostics.keychainAccessGroup = group
            return .success(AppearanceBackendRecord(data: data, accessGroup: group))
        }
        let records: [(AppearanceBackendRecord, Date)] = entries.compactMap { attributes in
            guard let data = attributes[kSecValueData as String] as? Data,
                  data.count <= AppearanceSyncClient.maximumPayloadBytes else { return nil }
            let date: Date?
            if account == AppearanceSyncClient.settingsAccount || account.hasPrefix(AppearanceSyncClient.settingsAccount + ".patch.") { date = try? AppearanceSyncClient.decode(data).get().updatedAt }
            else { date = try? AppearanceSyncClient.decodeReceipt(data).get().updatedAt }
            guard let date else { return nil }
            return (AppearanceBackendRecord(data: data, accessGroup: attributes[kSecAttrAccessGroup as String] as? String), date)
        }
        guard let newest = records.max(by: { $0.1 < $1.1 })?.0 else { return .failure(.invalidPayload) }
        diagnostics.keychainAccessGroup = newest.accessGroup
        return .success(newest)
    }
    func write(_ data: Data, account: String) -> Result<String?, AppearanceSyncError> {
        guard data.count <= AppearanceSyncClient.maximumPayloadBytes else { return .failure(.invalidPayload) }
        if account == AppearanceSyncClient.settingsAccount {
            guard let envelope = try? AppearanceSyncClient.decode(data).get() else { return .failure(.invalidPayload) }
            guard let baselineData = try? AppearanceSyncClient.encode(envelope.initialBaseline()).get() else { return .failure(.invalidPayload) }
            // First writer establishes the fallback values atomically. Unlike
            // deltas, this record is never replaced or compacted away.
            var baseline = query(account)
            baseline[kSecValueData as String] = baselineData
            baseline[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            var status = SecItemAdd(baseline as CFDictionary, nil)
            if status == errSecMissingEntitlement {
                baseline.removeValue(forKey: kSecAttrAccessGroup as String)
                status = SecItemAdd(baseline as CFDictionary, nil)
            }
            guard status == errSecSuccess || status == errSecDuplicateItem else { return .failure(.keychain(status)) }
            // Append immutable deltas. Two processes can never overwrite each
            // other's unrelated edits, even without a shared filesystem group.
            let result = write(data, account: account + ".patch." + envelope.revision.uuidString)
            if case .success = result {
                patchWrites += 1
                if patchWrites % 16 == 0 { prunePatches() }
            }
            return result
        }
        var base = query(account)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var add = base
        for (key, value) in values { add[key] = value }
        add[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        var status = SecItemAdd(add as CFDictionary, &attributes)
        if status == errSecMissingEntitlement {
            base.removeValue(forKey: kSecAttrAccessGroup as String)
            add.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(add as CFDictionary, &attributes)
        }
        diagnostics.operation = "keychain-write"; diagnostics.keychainWriteStatus = status
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base as CFDictionary, values as CFDictionary)
            diagnostics.keychainWriteStatus = status
            guard status == errSecSuccess else { return .failure(.keychain(status)) }
            // Query the stored item to report the actual group Security assigned.
            return read(account: account).flatMap { record in
                guard let record else { return .failure(.invalidPayload) }
                return .success(record.accessGroup)
            }
        }
        guard status == errSecSuccess else { return .failure(.keychain(status)) }
        let group = (attributes as? [String: Any])?[kSecAttrAccessGroup as String] as? String
        diagnostics.keychainAccessGroup = group
        return .success(group)
    }
    private func prunePatches() {
        var request = query(AppearanceSyncClient.settingsAccount)
        request.removeValue(forKey: kSecAttrAccount as String)
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        request[kSecReturnAttributes as String] = true; request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let entries = result as? [[String: Any]] else { return }
        let patches = entries.compactMap { attributes -> (String, AppearanceEnvelope, String?)? in
            guard let name = attributes[kSecAttrAccount as String] as? String,
                  name.hasPrefix(AppearanceSyncClient.settingsAccount + ".patch."),
                  let data = attributes[kSecValueData as String] as? Data,
                  let value = try? AppearanceSyncClient.decode(data).get() else { return nil }
            return (name, value, attributes[kSecAttrAccessGroup as String] as? String)
        }.sorted { $0.1.updatedAt > $1.1.updatedAt }
        guard patches.count > 96 else { return }
        var keep = Set(patches.prefix(64).map(\.0))
        var winners: [String: (Date, String, String)] = [:]
        for patch in patches {
            for field in patch.1.changedFields ?? Array(AppearanceSnapshot.fieldNames) {
                let date = patch.1.fieldDates?[field] ?? patch.1.updatedAt, revision = patch.1.revision.uuidString
                if let old = winners[field], old.0 > date || (old.0 == date && old.1 >= revision) { continue }
                winners[field] = (date, revision, patch.0)
            }
        }
        keep.formUnion(winners.values.map { $0.2 })
        for patch in patches where !keep.contains(patch.0) {
            var deletion = query(patch.0)
            if let group = patch.2 { deletion[kSecAttrAccessGroup as String] = group }
            SecItemDelete(deletion as CFDictionary)
        }
    }
    /// Used only by isolated test fixtures, never a broad keychain deletion.
    func remove(account: String) -> OSStatus {
        if account == AppearanceSyncClient.settingsAccount {
            var request = query(account); request.removeValue(forKey: kSecAttrAccount as String)
            request.removeValue(forKey: kSecAttrAccessGroup as String)
            request[kSecMatchLimit as String] = kSecMatchLimitAll; request[kSecReturnAttributes as String] = true
            var found: CFTypeRef?
            if SecItemCopyMatching(request as CFDictionary, &found) == errSecSuccess, let rows = found as? [[String: Any]] {
                for row in rows {
                    guard let name = row[kSecAttrAccount as String] as? String, name.hasPrefix(account + ".patch.") else { continue }
                    var deletion = query(name)
                    if let group = row[kSecAttrAccessGroup as String] as? String { deletion[kSecAttrAccessGroup as String] = group }
                    SecItemDelete(deletion as CFDictionary)
                }
            }
        }
        var query = query(account); query.removeValue(forKey: kSecAttrAccessGroup as String)
        return SecItemDelete(query as CFDictionary)
    }
}

struct AppearanceSyncRead {
    let envelope: AppearanceEnvelope
    let accessGroup: String?
}
struct AppearanceSyncWrite {
    let revision: UUID
    let accessGroup: String?
}
struct AppearanceReceiptRead {
    let receipt: AppearanceReceipt
    let accessGroup: String?
}

/// All Security I/O is serialized away from key events and the main thread.
/// Rapid slider edits collapse to the latest value; activation can flush it.
final class AppearanceSyncClient {
    static let maximumPayloadBytes = 16_384
    static let settingsAccount = "appearance"
    static let receiptAccount = "keyboard-receipt"
    private let backend: AppearanceSyncBackend
    private let queue = DispatchQueue(label: "clear.appearance.sync", qos: .utility)
    private let coalesceInterval: TimeInterval
    private var pending: (AppearanceEnvelope, (() -> Void)?, (Result<AppearanceSyncWrite, AppearanceSyncError>) -> Void)?
    private var scheduled: DispatchWorkItem?
    private var diagnosticsHandler: ((AppearanceBackendDiagnostics) -> Void)?
    init(backend: AppearanceSyncBackend = AppearanceKeychainBackend(), coalesceInterval: TimeInterval = 0.08) {
        self.backend = backend; self.coalesceInterval = max(0, coalesceInterval)
    }
    func observeDiagnostics(_ handler: @escaping (AppearanceBackendDiagnostics) -> Void) {
        queue.async { [self] in diagnosticsHandler = handler }
    }
    private func reportDiagnostics() {
        guard let handler = diagnosticsHandler else { return }
        let value = backend.diagnostics
        DispatchQueue.main.async { handler(value) }
    }
    static func encode(_ envelope: AppearanceEnvelope) -> Result<Data, AppearanceSyncError> {
        guard envelope.schema == 1 else { return .failure(.unsupportedSchema(envelope.schema)) }
        guard envelope.snapshot.isValid, envelope.hasValidFields, envelope.updatedAt.timeIntervalSince1970.isFinite,
              let data = try? JSONEncoder().encode(envelope), data.count <= maximumPayloadBytes else { return .failure(.invalidPayload) }
        return .success(data)
    }
    static func decode(_ data: Data) -> Result<AppearanceEnvelope, AppearanceSyncError> {
        guard data.count <= maximumPayloadBytes,
              let envelope = try? JSONDecoder().decode(AppearanceEnvelope.self, from: data) else { return .failure(.invalidPayload) }
        guard envelope.schema == 1 else { return .failure(.unsupportedSchema(envelope.schema)) }
        guard envelope.snapshot.isValid, envelope.hasValidFields, envelope.updatedAt.timeIntervalSince1970.isFinite else { return .failure(.invalidPayload) }
        return .success(envelope)
    }
    static func encodeReceipt(_ receipt: AppearanceReceipt) -> Result<Data, AppearanceSyncError> {
        guard receipt.schema == 2 else { return .failure(.unsupportedSchema(receipt.schema)) }
        guard receipt.snapshot.isValid, receipt.receiver.isValid, receipt.updatedAt.timeIntervalSince1970.isFinite,
              let data = try? JSONEncoder().encode(receipt), data.count <= maximumPayloadBytes else { return .failure(.invalidPayload) }
        return .success(data)
    }
    static func decodeReceipt(_ data: Data) -> Result<AppearanceReceipt, AppearanceSyncError> {
        guard data.count <= maximumPayloadBytes,
              let receipt = try? JSONDecoder().decode(AppearanceReceipt.self, from: data),
              receipt.updatedAt.timeIntervalSince1970.isFinite, receipt.snapshot.isValid,
              receipt.receiver.isValid else { return .failure(.invalidPayload) }
        guard receipt.schema == 2 else { return .failure(.unsupportedSchema(receipt.schema)) }
        return .success(receipt)
    }
    func publish(_ envelope: AppearanceEnvelope, didPersist: (() -> Void)? = nil,
                 completion: @escaping (Result<AppearanceSyncWrite, AppearanceSyncError>) -> Void) {
        queue.async { [self] in
            scheduled?.cancel()
            if let old = pending { deliver(.failure(.superseded), to: old.2) }
            pending = (envelope, didPersist, completion)
            let work = DispatchWorkItem { [weak self] in self?.flushPending() }
            scheduled = work
            queue.asyncAfter(deadline: .now() + coalesceInterval, execute: work)
        }
    }
    func flush(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            flushPending()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }
    private func flushPending() {
        scheduled?.cancel(); scheduled = nil
        guard let (envelope, didPersist, completion) = pending else { return }
        pending = nil
        let result = Self.encode(envelope).flatMap { backend.write($0, account: Self.settingsAccount) }
            .map { AppearanceSyncWrite(revision: envelope.revision, accessGroup: $0) }
        reportDiagnostics()
        // A suspended containing App may not run its main callback yet. Notify
        // the keyboard on the persistence queue as soon as the value is durable.
        if case .success = result { didPersist?() }
        deliver(result, to: completion)
    }
    func load(completion: @escaping (Result<AppearanceSyncRead?, AppearanceSyncError>) -> Void) {
        queue.async { [self] in
            flushPending()
            let result = backend.read(account: Self.settingsAccount).flatMap { record -> Result<AppearanceSyncRead?, AppearanceSyncError> in
                guard let record else { return .success(nil) }
                return Self.decode(record.data).map { AppearanceSyncRead(envelope: $0, accessGroup: record.accessGroup) }
            }
            reportDiagnostics()
            deliver(result, to: completion)
        }
    }
    func writeReceipt(revision: UUID, snapshot: AppearanceSnapshot, receiver: AppearanceReceiverIdentity,
                      didPersist: (() -> Void)? = nil,
                      completion: @escaping (Result<AppearanceSyncWrite, AppearanceSyncError>) -> Void = { _ in }) {
        queue.async { [self] in
            let result = Self.encodeReceipt(AppearanceReceipt(revision: revision, snapshot: snapshot, receiver: receiver)).flatMap { backend.write($0, account: Self.receiptAccount) }
                .map { AppearanceSyncWrite(revision: revision, accessGroup: $0) }
            reportDiagnostics()
            if case .success = result { didPersist?() }
            deliver(result, to: completion)
        }
    }
    func readReceipt(completion: @escaping (Result<AppearanceReceiptRead?, AppearanceSyncError>) -> Void) {
        queue.async { [self] in
            let result = backend.read(account: Self.receiptAccount).flatMap { record -> Result<AppearanceReceiptRead?, AppearanceSyncError> in
                guard let record else { return .success(nil) }
                return Self.decodeReceipt(record.data).map { AppearanceReceiptRead(receipt: $0, accessGroup: record.accessGroup) }
            }
            reportDiagnostics()
            deliver(result, to: completion)
        }
    }
    private func deliver<T>(_ result: Result<T, AppearanceSyncError>, to completion: @escaping (Result<T, AppearanceSyncError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }
}
