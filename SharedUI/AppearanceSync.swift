import Foundation
import Security

/// Only appearance travels through this channel. Input text, learned words,
/// clipboard contents and language state remain in their existing stores.
struct AppearanceSnapshot: Codable, Equatable {
    let glass: GlassPreset
    let accent: Accent
    let customAccentHex: String?
    let glassOpacity: Double
    let backgroundGlassStrength: Double?
    let keyGlassStrength: Double?
    let backgroundColorHex: String?
    let keyColorHex: String?
    let candidateColorHex: String?
    let candidateTextSize: CandidateTextSize?

    init(settings: KeyboardSettings) {
        var value = settings; value.sanitize()
        glass = value.glass; accent = value.accent; customAccentHex = value.customAccentHex
        glassOpacity = value.glassOpacity
        backgroundGlassStrength = value.backgroundGlassStrength; keyGlassStrength = value.keyGlassStrength
        backgroundColorHex = value.backgroundColorHex; keyColorHex = value.keyColorHex
        candidateColorHex = value.candidateColorHex; candidateTextSize = value.candidateTextSize
    }
    func applying(to settings: KeyboardSettings) -> KeyboardSettings {
        var value = settings
        value.glass = glass; value.accent = accent; value.customAccentHex = customAccentHex
        value.glassOpacity = glassOpacity
        value.backgroundGlassStrength = backgroundGlassStrength; value.keyGlassStrength = keyGlassStrength
        value.backgroundColorHex = backgroundColorHex; value.keyColorHex = keyColorHex
        value.candidateColorHex = candidateColorHex; value.candidateTextSize = candidateTextSize
        // The snapshot is normalized on creation and validated on decode.
        // Do not run unrelated language/learning migrations while applying it.
        return value
    }
    var isValid: Bool {
        let strengths = [glassOpacity] + [backgroundGlassStrength, keyGlassStrength].compactMap { $0 }
        guard strengths.allSatisfy({ $0.isFinite && (0...1).contains($0) }), glassOpacity >= 0.15 else { return false }
        for color in [customAccentHex, backgroundColorHex, keyColorHex, candidateColorHex].compactMap({ $0 }) {
            guard RGBColor(hex: color)?.hex == color else { return false }
        }
        return true
    }
}

struct AppearanceEnvelope: Codable, Equatable {
    let schema: Int
    let revision: UUID
    let updatedAt: Date
    let snapshot: AppearanceSnapshot
    init(snapshot: AppearanceSnapshot, revision: UUID = UUID(), updatedAt: Date = Date()) {
        schema = 1; self.revision = revision; self.updatedAt = updatedAt; self.snapshot = snapshot
    }
}

struct AppearanceReceipt: Codable, Equatable {
    let schema: Int
    let revision: UUID
    let updatedAt: Date
    init(revision: UUID, updatedAt: Date = Date()) {
        schema = 1; self.revision = revision; self.updatedAt = updatedAt
    }
}

enum AppearanceSyncError: Error, Equatable {
    case keychain(OSStatus)
    case invalidPayload
    case unsupportedSchema(Int)
    case superseded
}

struct AppearanceBackendRecord {
    let data: Data
    let accessGroup: String?
}

protocol AppearanceSyncBackend: AnyObject {
    func read(account: String) -> Result<AppearanceBackendRecord?, AppearanceSyncError>
    func write(_ data: Data, account: String) -> Result<String?, AppearanceSyncError>
}

/// Uses only the process's authorized keychain groups. Omitting an explicit
/// group lets Security choose its real default; it never fabricates permissions.
/// A successful local write is not evidence that the keyboard can read it.
final class AppearanceKeychainBackend: AppearanceSyncBackend {
    let service: String
    init(service: String = "com.clearkeyboard.appearance.sync.v1") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    func read(account: String) -> Result<AppearanceBackendRecord?, AppearanceSyncError> {
        var query = query(account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess else { return .failure(.keychain(status)) }
        guard let attributes = result as? [String: Any], let data = attributes[kSecValueData as String] as? Data else { return .failure(.invalidPayload) }
        guard data.count <= AppearanceSyncClient.maximumPayloadBytes else { return .failure(.invalidPayload) }
        return .success(AppearanceBackendRecord(data: data, accessGroup: attributes[kSecAttrAccessGroup as String] as? String))
    }
    func write(_ data: Data, account: String) -> Result<String?, AppearanceSyncError> {
        guard data.count <= AppearanceSyncClient.maximumPayloadBytes else { return .failure(.invalidPayload) }
        let base = query(account)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var add = base
        for (key, value) in values { add[key] = value }
        add[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        var status = SecItemAdd(add as CFDictionary, &attributes)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base as CFDictionary, values as CFDictionary)
            guard status == errSecSuccess else { return .failure(.keychain(status)) }
            // Query the stored item to report the actual group Security assigned.
            return read(account: account).flatMap { record in
                guard let record else { return .failure(.invalidPayload) }
                return .success(record.accessGroup)
            }
        }
        guard status == errSecSuccess else { return .failure(.keychain(status)) }
        let group = (attributes as? [String: Any])?[kSecAttrAccessGroup as String] as? String
        return .success(group)
    }
    /// Used only by isolated test fixtures, never a broad keychain deletion.
    func remove(account: String) -> OSStatus { SecItemDelete(query(account) as CFDictionary) }
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
    private var pending: (AppearanceEnvelope, (Result<AppearanceSyncWrite, AppearanceSyncError>) -> Void)?
    private var scheduled: DispatchWorkItem?
    init(backend: AppearanceSyncBackend = AppearanceKeychainBackend(), coalesceInterval: TimeInterval = 0.08) {
        self.backend = backend; self.coalesceInterval = max(0, coalesceInterval)
    }
    static func encode(_ envelope: AppearanceEnvelope) -> Result<Data, AppearanceSyncError> {
        guard envelope.schema == 1 else { return .failure(.unsupportedSchema(envelope.schema)) }
        guard envelope.snapshot.isValid, envelope.updatedAt.timeIntervalSince1970.isFinite,
              let data = try? JSONEncoder().encode(envelope), data.count <= maximumPayloadBytes else { return .failure(.invalidPayload) }
        return .success(data)
    }
    static func decode(_ data: Data) -> Result<AppearanceEnvelope, AppearanceSyncError> {
        guard data.count <= maximumPayloadBytes,
              let envelope = try? JSONDecoder().decode(AppearanceEnvelope.self, from: data) else { return .failure(.invalidPayload) }
        guard envelope.schema == 1 else { return .failure(.unsupportedSchema(envelope.schema)) }
        guard envelope.snapshot.isValid, envelope.updatedAt.timeIntervalSince1970.isFinite else { return .failure(.invalidPayload) }
        return .success(envelope)
    }
    static func encodeReceipt(_ receipt: AppearanceReceipt) -> Result<Data, AppearanceSyncError> {
        guard receipt.schema == 1 else { return .failure(.unsupportedSchema(receipt.schema)) }
        guard receipt.updatedAt.timeIntervalSince1970.isFinite,
              let data = try? JSONEncoder().encode(receipt), data.count <= maximumPayloadBytes else { return .failure(.invalidPayload) }
        return .success(data)
    }
    static func decodeReceipt(_ data: Data) -> Result<AppearanceReceipt, AppearanceSyncError> {
        guard data.count <= maximumPayloadBytes,
              let receipt = try? JSONDecoder().decode(AppearanceReceipt.self, from: data),
              receipt.updatedAt.timeIntervalSince1970.isFinite else { return .failure(.invalidPayload) }
        guard receipt.schema == 1 else { return .failure(.unsupportedSchema(receipt.schema)) }
        return .success(receipt)
    }
    func publish(_ envelope: AppearanceEnvelope, completion: @escaping (Result<AppearanceSyncWrite, AppearanceSyncError>) -> Void) {
        queue.async { [self] in
            scheduled?.cancel()
            if let old = pending { deliver(.failure(.superseded), to: old.1) }
            pending = (envelope, completion)
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
        guard let (envelope, completion) = pending else { return }
        pending = nil
        let result = Self.encode(envelope).flatMap { backend.write($0, account: Self.settingsAccount) }
            .map { AppearanceSyncWrite(revision: envelope.revision, accessGroup: $0) }
        deliver(result, to: completion)
    }
    func load(completion: @escaping (Result<AppearanceSyncRead?, AppearanceSyncError>) -> Void) {
        queue.async { [self] in
            flushPending()
            let result = backend.read(account: Self.settingsAccount).flatMap { record -> Result<AppearanceSyncRead?, AppearanceSyncError> in
                guard let record else { return .success(nil) }
                return Self.decode(record.data).map { AppearanceSyncRead(envelope: $0, accessGroup: record.accessGroup) }
            }
            deliver(result, to: completion)
        }
    }
    func writeReceipt(revision: UUID, completion: @escaping (Result<AppearanceSyncWrite, AppearanceSyncError>) -> Void = { _ in }) {
        queue.async { [self] in
            let result = Self.encodeReceipt(AppearanceReceipt(revision: revision)).flatMap { backend.write($0, account: Self.receiptAccount) }
                .map { AppearanceSyncWrite(revision: revision, accessGroup: $0) }
            deliver(result, to: completion)
        }
    }
    func readReceipt(completion: @escaping (Result<AppearanceReceiptRead?, AppearanceSyncError>) -> Void) {
        queue.async { [self] in
            let result = backend.read(account: Self.receiptAccount).flatMap { record -> Result<AppearanceReceiptRead?, AppearanceSyncError> in
                guard let record else { return .success(nil) }
                return Self.decodeReceipt(record.data).map { AppearanceReceiptRead(receipt: $0, accessGroup: record.accessGroup) }
            }
            deliver(result, to: completion)
        }
    }
    private func deliver<T>(_ result: Result<T, AppearanceSyncError>, to completion: @escaping (Result<T, AppearanceSyncError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }
}
