import Foundation
import Dispatch
import CoreFoundation
#if canImport(V21NativeIME)
import V21NativeIME
#endif

/// User-started numeric timing only. Startup history is bounded in memory;
/// typing is never captured until Start, and no input/candidate text is stored.
final class KernelMeasurement: @unchecked Sendable {
    static let shared=KernelMeasurement()
    let recorder=V22PerformanceRecorder()
    private let lock=NSLock()
    private let writer=DispatchQueue(label:"clear.v22.measurement.export",qos:.utility)
    private static let notification="com.clearkeyboard.v22.measurement.changed"
    private static let flushNotification="com.clearkeyboard.v22.measurement.flush"
    private struct Capture {let id:String;let start:UInt64;let stop:UInt64?;let expiry:Double}
    private var capture:Capture?
    private var currentID:String?
    private var lastID:String?
    private var acceptedRecords=0
    private var versions=Set<UInt64>()
    private var receivedKeys=Set<String>()
    private var pendingWrite:DispatchWorkItem?
    private var startup:[[String:String]]=[]
    private init() {
        let pointer=Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),pointer,{_,p,_,_,_ in
            guard let p else{return};Unmanaged<KernelMeasurement>.fromOpaque(p).takeUnretainedValue().refreshSession()
        },Self.notification as CFString,nil,.deliverImmediately)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),pointer,{_,p,_,_,_ in
            guard let p else{return};let owner=Unmanaged<KernelMeasurement>.fromOpaque(p).takeUnretainedValue();owner.refreshSession();owner.flushNow()
        },Self.flushNotification as CFString,nil,.deliverImmediately)
        refreshSession()
    }
    deinit {CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),Unmanaged.passUnretained(self).toOpaque())}
    var directory:URL {
        #if SWIFT_PACKAGE
        let root=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!
        #else
        let root=SharedStorage.applicationGroup()?.root ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!
        #endif
        return root.appendingPathComponent("V22UserMeasurement",isDirectory:true)
    }
    private var sharedContainerAvailable:Bool {
        #if SWIFT_PACKAGE
        return false
        #else
        return SharedStorage.applicationGroup() != nil
        #endif
    }
    private var role:String {Bundle.main.bundleURL.pathExtension == "appex" ? "keyboard":"app"}
    private var commandURL:URL {directory.appendingPathComponent("session.json")}
    func noteStartup(_ phase:String) {
        lock.lock()
        if startup.count<24 {startup.append(["phase":phase,"uptime_ns":String(DispatchTime.now().uptimeNanoseconds),"process_id":String(ProcessInfo.processInfo.processIdentifier)])}
        let active=capture.map{$0.stop == nil && $0.expiry>Date().timeIntervalSince1970} ?? false
        lock.unlock()
        if active {scheduleWrite()}
    }
    func refreshSession() {
        var next:Capture?
        if let data=try? Data(contentsOf:commandURL),data.count<2048,
           let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           let id=value["id"] as? String,let start=value["startNS"] as? UInt64,let expiry=value["expires"] as? Double,expiry>Date().timeIntervalSince1970 {
            next=Capture(id:id,start:start,stop:value["stopNS"] as? UInt64,expiry:expiry)
        }
        lock.lock();let changed=capture?.id != next?.id || capture?.stop != next?.stop;capture=next
        if let next,currentID != next.id {
            currentID=next.id;lastID=next.id;acceptedRecords=0;versions.removeAll();receivedKeys.removeAll();recorder.clear()
        }
        lock.unlock()
        if let next,next.stop == nil || changed {scheduleWrite()}
    }
    private func signal(_ name:String) {CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFNotificationName(rawValue:name as CFString),nil,nil,true)}
    @discardableResult func startCapture() throws -> String {
        let id=UUID().uuidString
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let data=try JSONSerialization.data(withJSONObject:["id":id,"expires":Date().timeIntervalSince1970+1800,"startNS":DispatchTime.now().uptimeNanoseconds] as [String:Any])
        try data.write(to:commandURL,options:.atomic);refreshSession();signal(Self.notification);return id
    }
    func stopCapture() throws {
        if let data=try? Data(contentsOf:commandURL),var value=try JSONSerialization.jsonObject(with:data) as? [String:Any] {
            value["stopNS"]=DispatchTime.now().uptimeNanoseconds
            try JSONSerialization.data(withJSONObject:value).write(to:commandURL,options:.atomic)
        }
        refreshSession();signal(Self.notification);signal(Self.flushNotification);flushNow()
    }
    private func enabled(_ inputNS:UInt64) -> Bool {
        lock.lock();defer{lock.unlock()}
        guard let capture,capture.expiry>Date().timeIntervalSince1970,inputNS>=capture.start else{return false}
        return capture.stop.map{inputNS <= $0} ?? true
    }
    func isRecording() -> Bool {
        guard enabled(DispatchTime.now().uptimeNanoseconds) else{return false}
        lock.lock();defer{lock.unlock()};return versions.count<200
    }
    func observes(_ timing:V22AppTiming) -> Bool {
        guard enabled(timing.inputNS) else{return false}
        lock.lock();defer{lock.unlock()};return versions.contains(timing.inputVersion) || versions.count<200
    }
    func activeSessionID() -> String? {lock.lock();defer{lock.unlock()};return currentID}
    func receive(_ value:V21PerformanceRecord) {
        guard enabled(value.timings.sdkEntryUptimeNS) else{return}
        lock.lock();guard acceptedRecords<200,versions.contains(value.inputVersion) || versions.count<200 else{lock.unlock();return};acceptedRecords+=1;versions.insert(value.inputVersion);lock.unlock()
        recorder.receive(value);scheduleWrite()
    }
    func preparationFailed(_ error:Error) {
        noteStartup("prepare_failed")
        guard isRecording() else{return};recorder.receivePreparationFailure(error);scheduleWrite()
    }
    func appReceived(_ value:V22AppTiming) {
        guard enabled(value.inputNS) else{return}
        let key="\(value.inputVersion):\(value.phase):\(value.displayStatus ?? "")"
        lock.lock()
        guard versions.contains(value.inputVersion) || versions.count<200,receivedKeys.count<4096,receivedKeys.insert(key).inserted else{lock.unlock();return}
        versions.insert(value.inputVersion);lock.unlock()
        recorder.receiveAppTiming(value);scheduleWrite()
    }
    private func scheduleWrite() {
        lock.lock();guard lastID != nil,pendingWrite == nil else{lock.unlock();return}
        let work=DispatchWorkItem{[weak self] in
            guard let self else{return};self.lock.lock();self.pendingWrite=nil;self.lock.unlock();self.writeSnapshot()
        }
        pendingWrite=work;lock.unlock()
        // Batching prevents JSON/file IO on every draw/commit callback.
        writer.asyncAfter(deadline:.now()+0.5,execute:work)
    }
    private func flushNow() {
        lock.lock();pendingWrite?.cancel();pendingWrite=nil;lock.unlock()
        writer.async{[weak self] in self?.writeSnapshot()}
    }
    private func writeSnapshot() {
        lock.lock()
        guard let id=lastID else{lock.unlock();return}
        let history=startup,value=recorder.snapshot();lock.unlock()
        do {
            let encoder=JSONEncoder()
            let object:[String:Any]=["schema":"v22-process-display-snapshot-2","session_id":id,"process_role":role,
                "process_id":ProcessInfo.processInfo.processIdentifier,"build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown",
                "snapshot_written_uptime_ns":DispatchTime.now().uptimeNanoseconds,"shared_container_available":sharedContainerAvailable,
                "startup_timeline":history,"records":try JSONSerialization.jsonObject(with:encoder.encode(value.records)),
                "app_times":try JSONSerialization.jsonObject(with:encoder.encode(value.appEvents)),"preparation_failures":value.preparationFailures,
                "dropped":value.dropped,"screen_visibility":"draw/commit/next-refresh observed in this process; host physical presentation unmeasured; estimatedPresentationNS is an estimate","tests_passed":false]
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:directory.appendingPathComponent("\(id)-\(role).json"),options:.atomic)
        } catch { /* Missing evidence is explicit at export. */ }
    }
    func export(id:String,finiteSession:URL?) async throws -> URL {
        let requested=DispatchTime.now().uptimeNanoseconds
        signal(Self.flushNotification);flushNow()
        await withCheckedContinuation{(c:CheckedContinuation<Void,Never>) in writer.async{c.resume()}}
        let keyboard=directory.appendingPathComponent("\(id)-keyboard.json")
        // One bounded export handshake, not a monitor. A suspended/nonexistent
        // extension may not acknowledge; report its actual file state unchanged.
        for _ in 0..<6 {
            if let data=try? Data(contentsOf:keyboard),let v=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
               let written=v["snapshot_written_uptime_ns"] as? UInt64,written>=requested {break}
            try? await Task.sleep(nanoseconds:50_000_000)
        }
        var processes:[String:Any]=[:]
        for role in ["app","keyboard"] {
            if let data=try? Data(contentsOf:directory.appendingPathComponent("\(id)-\(role).json")),data.count<12_000_000 {processes[role]=try JSONSerialization.jsonObject(with:data)}
        }
        let resultRole=processes["keyboard"] as? [String:Any]
        let keyboardRows=(resultRole?["records"] as? [Any])?.count ?? 0,keyboardFrames=(resultRole?["app_times"] as? [Any])?.count ?? 0
        var result:[String:Any]=["schema":"clear-v22-user-export-2","build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown","kernel":"V22","session_id":id,"processes":processes,
            "keyboard_evidence_available":resultRole != nil,"keyboard_request_count":keyboardRows,"keyboard_display_event_count":keyboardFrames,
            "shared_container_available":sharedContainerAvailable,"screen_visible_latency":"drawing, process commit and next-refresh callback measured; physical host/screen presentation unmeasured",
            "input_origin":"accepted composition query creation, not finger-down","estimated_presentation_caveat":"UIKit estimatedPresentationTime converted to monotonic nanoseconds; not physical visibility",
            "export_flush_requested_uptime_ns":requested,"capture_limit_per_process":200,"capture_expiry_seconds":1800,"tests_passed":false]
        if let finiteSession {result["finite_sdk_session"]=try JSONSerialization.jsonObject(with:Data(contentsOf:finiteSession))}
        let out=FileManager.default.temporaryDirectory.appendingPathComponent("ClearKeyboard-V22-\(id).json")
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out,options:.atomic);return out
    }
}
