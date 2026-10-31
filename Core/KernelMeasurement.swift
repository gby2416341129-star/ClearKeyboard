import Foundation
import Dispatch
#if canImport(V21NativeIME)
import V21NativeIME
#endif

/// User-started, bounded local capture. No typing text is written and no work runs while idle.
final class KernelMeasurement: @unchecked Sendable {
    static let shared = KernelMeasurement()
    let recorder = V22PerformanceRecorder()
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "clear.v22.measurement.export", qos: .utility)
    private var currentID: String?
    private var lastID: String?
    private var pendingWrite = false
    private var acceptedRecords = 0
    private var receivedKeys = Set<String>()
    var directory: URL {
        #if SWIFT_PACKAGE
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        let root = SharedStorage.applicationGroup()?.root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #endif
        return root.appendingPathComponent("V22UserMeasurement", isDirectory: true)
    }
    private var role: String { Bundle.main.bundleURL.pathExtension == "appex" ? "keyboard" : "app" }
    private var commandURL: URL { directory.appendingPathComponent("session.json") }
    private func command(inputNS: UInt64) -> String? {
        guard let data = try? Data(contentsOf: commandURL), data.count < 2048,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = value["expires"] as? Double, expiry > Date().timeIntervalSince1970 else { return nil }
        guard let start = value["startNS"] as? UInt64, inputNS >= start else { return nil }
        if let stop = value["stopNS"] as? UInt64, inputNS > stop { return nil }
        return value["id"] as? String
    }
    @discardableResult func startCapture() throws -> String {
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "expires": Date().timeIntervalSince1970 + 1800, "startNS": DispatchTime.now().uptimeNanoseconds] as [String: Any])
        try data.write(to: commandURL, options: .atomic)
        return id
    }
    func stopCapture() throws {
        if let data = try? Data(contentsOf: commandURL), var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            value["stopNS"] = DispatchTime.now().uptimeNanoseconds
            try JSONSerialization.data(withJSONObject: value).write(to: commandURL, options: .atomic)
        }
        scheduleWrite()
    }
    private func captureEnabled(inputNS: UInt64) -> Bool {
        let id = command(inputNS: inputNS)
        lock.lock(); defer { lock.unlock() }
        guard let id else { return false }
        if currentID != id {
            currentID = id; lastID = id; acceptedRecords = 0; receivedKeys.removeAll(); recorder.clear()
        }
        return acceptedRecords < 200
    }
    func receive(_ value: V21PerformanceRecord) {
        guard captureEnabled(inputNS: value.timings.sdkEntryUptimeNS) else { return }
        lock.lock(); acceptedRecords += 1; lock.unlock()
        recorder.receive(value); scheduleWrite()
    }
    func preparationFailed(_ error: Error) {
        guard captureEnabled(inputNS: DispatchTime.now().uptimeNanoseconds) else { return }
        recorder.receivePreparationFailure(error); scheduleWrite()
    }
    func appReceived(_ value: V22AppTiming) {
        guard captureEnabled(inputNS: value.inputNS) else { return }
        let key = "\(value.inputVersion):\(value.phase)"
        lock.lock(); let first = receivedKeys.insert(key).inserted; lock.unlock()
        guard first else { return }
        recorder.receiveAppTiming(value); scheduleWrite()
    }
    private func scheduleWrite() {
        lock.lock()
        guard lastID != nil, !pendingWrite else { lock.unlock(); return }
        pendingWrite = true; lock.unlock()
        writer.async {
            self.lock.lock(); let id = self.lastID; self.pendingWrite = false; self.lock.unlock()
            guard let id else { return }
            let url = self.directory.appendingPathComponent("\(id)-\(self.role).json")
            do { try self.recorder.exportSnapshot(to: url) }
            catch { /* Export reports missing process evidence rather than fabricating it. */ }
        }
    }
    /// Collect only this opt-in session. Missing keyboard evidence is explicit.
    func export(id: String, finiteSession: URL?) async throws -> URL {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.async { continuation.resume() } }
        var processes: [String: Any] = [:]
        for role in ["app", "keyboard"] {
            let p = directory.appendingPathComponent("\(id)-\(role).json")
            if let data = try? Data(contentsOf: p), data.count < 8_000_000 {
                processes[role] = try JSONSerialization.jsonObject(with: data)
            }
        }
        var result: [String: Any] = ["schema": "clear-v22-user-export-1", "build": "95", "kernel": "V22",
            "session_id": id, "processes": processes, "keyboard_evidence_available": processes["keyboard"] != nil,
            "screen_visible_latency": "unmeasured; App receipt is not screen visibility",
            "capture_limit_per_process": 200, "capture_expiry_seconds": 1800, "tests_passed": false]
        if let finiteSession { result["finite_sdk_session"] = try JSONSerialization.jsonObject(with: Data(contentsOf: finiteSession)) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ClearKeyboard-V22-build95-\(id).json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out, options: .atomic)
        return out
    }
}
