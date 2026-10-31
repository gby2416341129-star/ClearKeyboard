import Foundation
import Dispatch

/// Explicit-session recorder. No files, timers, inference or logging while idle.
public final class V22PerformanceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [V21PerformanceRecord] = []
    private var dropped = 0
    private var appEvents: [V22AppTiming] = []
    private var preparationFailures:[[String:String]]=[]
    public init() {}
    public func receive(_ value: V21PerformanceRecord) {
        lock.lock(); defer { lock.unlock() }
        if records.count < 256 { records.append(value) } else { dropped += 1 }
    }
    public func receiveAppTiming(_ value:V22AppTiming) {
        lock.lock();defer {lock.unlock()};if appEvents.count<4096 {appEvents.append(value)}
    }
    public func receivePreparationFailure(_ error:Error) {
        let value=error as NSError
        lock.lock();defer {lock.unlock()}
        if preparationFailures.count<8 {preparationFailures.append(["stage":"prepare_failed","domain":value.domain,"code":String(value.code),"error":value.localizedDescription,"uptime_ns":String(DispatchTime.now().uptimeNanoseconds),"process_id":String(ProcessInfo.processInfo.processIdentifier)])}
    }
    public func snapshot() -> (records: [V21PerformanceRecord], dropped: Int, appEvents:[V22AppTiming],preparationFailures:[[String:String]]) {
        lock.lock(); defer { lock.unlock() }; return (records,dropped,appEvents,preparationFailures)
    }
    public func clear() { lock.lock();records.removeAll(keepingCapacity:true);appEvents.removeAll(keepingCapacity:true);preparationFailures.removeAll(keepingCapacity:true);dropped=0;lock.unlock() }
    /// Optional cold-input export before starting the ordinary warm session, which clears records.
    public func exportSnapshot(to url:URL) throws {
        let value=snapshot(),encoder=JSONEncoder()
        let object:[String:Any]=["schema":"v22-opt-in-performance-snapshot-1",
            "records":try JSONSerialization.jsonObject(with:encoder.encode(value.records)),
            "app_times":try JSONSerialization.jsonObject(with:encoder.encode(value.appEvents)),
            "preparation_failures":value.preparationFailures,"dropped":value.dropped,"screen_visibility":"App supplied only","tests_passed":false]
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:url,options:.atomic)
    }
}

public struct V22MeasurementProbe: Codable, Sendable {
    public let raw: String
    public let context: String
    public let scenario: String
    public let intervalMS: UInt64
    public let overlapping: Bool
    public init(raw: String, context: String, scenario: String, intervalMS: UInt64 = 0, overlapping: Bool = false) {
        self.raw=raw; self.context=context; self.scenario=scenario; self.intervalMS=intervalMS; self.overlapping=overlapping
    }
}

/// App timestamps use DispatchTime.now().uptimeNanoseconds, the same monotonic clock as SDK.
/// Set visibleNS only at the App's actual display callback/frame; received is not visible.
public struct V22AppTiming: Codable, Sendable {
    public let inputVersion: UInt64
    public let inputNS: UInt64
    public let prepareWaitStartNS: UInt64?
    public let prepareWaitEndNS: UInt64?
    public let receivedNS: UInt64?
    public let visibleNS: UInt64?
    public var sdkReturnedNS:UInt64?=nil
    public var appliedNS:UInt64?=nil
    public var drawnNS:UInt64?=nil
    public var transactionCommittedNS:UInt64?=nil
    public var nextRefreshNS:UInt64?=nil
    public var estimatedPresentationNS:UInt64?=nil
    public var displayStatus:String?=nil
    public let phase: String
    public init(inputVersion: UInt64, inputNS: UInt64, prepareWaitStartNS: UInt64? = nil,
                prepareWaitEndNS: UInt64? = nil, receivedNS: UInt64? = nil, visibleNS: UInt64? = nil, phase: String) {
        self.inputVersion=inputVersion;self.inputNS=inputNS;self.prepareWaitStartNS=prepareWaitStartNS
        self.prepareWaitEndNS=prepareWaitEndNS;self.receivedNS=receivedNS;self.visibleNS=visibleNS;self.phase=phase
    }
}

/// Use only after a user presses Start. Reuses the existing single model/kernel.
/// Stop cancels request signals; synchronous Core ML calls may return later. Export remains available.
public actor V22MeasurementSession {
    private let kernel: V21IMEKernel
    private let recorder: V22PerformanceRecorder
    private let configurationLabel: String
    private var running=false, stopping=false, completed=false
    private var requests: [UInt64:Task<Void,Never>] = [:]
    private var attempts: [UInt64:[String:String]] = [:]
    private var appTimes: [V22AppTiming] = []
    private var finalInputNS: UInt64?
    private var latestVersion: UInt64=0
    private var catchUpMS: Double?
    private var catchUpStatus: String="not_started"
    private var consecutiveStalls=0
    private var stopReason: String?
    public init(kernel: V21IMEKernel, recorder: V22PerformanceRecorder, configurationLabel: String) {
        self.kernel=kernel;self.recorder=recorder;self.configurationLabel=configurationLabel
    }
    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public func addAppTiming(_ value: V22AppTiming) {
        if appTimes.count < 512 { appTimes.append(value) }
    }
    public func stop() async {
        stopping=true;stopReason=stopReason ?? "user_stopped"
        for task in requests.values { task.cancel() }
        await kernel.cancelPending() // Explicit whole-session stop, never a stale per-query handler.
    }
    /// Finite supplied inputs; suggested 160 per configuration. No hidden warmups or 5000-case phone run.
    /// Do not use this concurrently with live typing. Recreate preparation when changing compute units.
    public func run(probes: [V22MeasurementProbe], firstVersion: UInt64,
                    stallLimitMS: Double = 2500, onProgress: (@Sendable (Int,Int) -> Void)? = nil) async throws {
        guard !running, !completed, (1...200).contains(probes.count), probes.allSatisfy({$0.intervalMS<=10_000}) else {
            throw V21Error.contract("Start one bounded session with1..200 probes; each wait <=10s")
        }
        running=true;stopping=false;recorder.clear()
        for (i,probe) in probes.enumerated() {
            if stopping || Task.isCancelled { break }
            if probe.intervalMS>0 {
                do { try await Task.sleep(nanoseconds:probe.intervalMS*1_000_000) }
                catch { stopping=true;stopReason="driver_cancelled";break }
            }
            if stopping { break }
            // Bound driver tasks as well as SDK work. Rapid-input bursts have at most8 callers.
            if !probe.overlapping || requests.count>=8 { await drainTasks() }
            if stopping { break }
            let version=firstVersion+UInt64(i), entered=now()
            latestVersion=version;finalInputNS=entered;catchUpMS=nil;catchUpStatus="waiting_for_latest_input"
            attempts[version]=["scenario":probe.scenario,"status":"dispatched","raw_utf8_length":String(probe.raw.utf8.count),"context_scalars":String(probe.context.unicodeScalars.count),"driver_input_ns":String(entered)]
            let task=Task { await self.perform(probe:probe,version:version,entered:entered,stallLimitMS:stallLimitMS) }
            requests[version]=task
            onProgress?(i+1,probes.count)
            if !probe.overlapping { await task.value;requests[version]=nil }
        }
        await drainTasks();running=false;completed=true
        if Task.isCancelled { stopReason=stopReason ?? "driver_cancelled" }
    }
    private func drainTasks() async {
        let pending=requests
        for (version,task) in pending { await task.value;requests[version]=nil }
    }
    private func perform(probe: V22MeasurementProbe, version: UInt64, entered: UInt64, stallLimitMS: Double) async {
        defer {requests[version]=nil}
        do {
            let result=try await kernel.candidates(rawPinyin:probe.raw,committedLeftContext:probe.context,
                inputVersion:version,onUpdate:{ _ in }) // Ordinary production route, no target/diagnose.
            let returned=now(),elapsed=Double(returned-entered)/1_000_000
            let status=result.map{$0.candidates.isEmpty ? "empty_"+$0.status.rawValue : "nonempty_final"} ?? "cancelled_or_superseded"
            attempts[version]?["status"]=status;attempts[version]?["driver_elapsed_ms"]=String(elapsed)
            if version==latestVersion { catchUpStatus=status;catchUpMS=status=="nonempty_final" ? elapsed : nil }
            if elapsed>stallLimitMS { consecutiveStalls+=1 } else { consecutiveStalls=0 }
            if consecutiveStalls>=3 { stopReason="three_consecutive_completed_calls_exceeded_stall_limit";await stop() }
        } catch {
            attempts[version]?["status"]=Task.isCancelled ? "cancelled" : "error"
            attempts[version]?["error"]=error.localizedDescription
            attempts[version]?["driver_elapsed_ms"]=String(Double(now()-entered)/1_000_000)
            if version==latestVersion { catchUpStatus="error_or_cancelled";catchUpMS=nil }
            consecutiveStalls+=1
            if consecutiveStalls>=3 { stopReason="three_consecutive_errors_or_stalls";await stop() }
        }
    }
    /// One user Export action, also available while Stop awaits an in-flight synchronous prediction.
    public func export(to url: URL) throws {
        let snapshot=recorder.snapshot(),encoder=JSONEncoder()
        let rows=try JSONSerialization.jsonObject(with:encoder.encode(snapshot.records))
        let app=try JSONSerialization.jsonObject(with:encoder.encode(snapshot.appEvents+appTimes))
        func stats(_ values:[Double]) -> [String:Any] {
            guard !values.isEmpty else { return ["n":0] }
            let a=values.sorted()
            func p(_ q:Double)->Double { a[max(0,Int(ceil(q*Double(a.count)))-1)] }
            return ["n":a.count,"p50_ms":p(0.50),"p95_ms":p(0.95),"p99_ms":p(0.99),"max_ms":a.last!]
        }
        var groups:[String:[V21PerformanceRecord]]=[:]
        for row in snapshot.records {
            let t=row.timings
            let warmth=t.firstPredictionInThisInstance ? "first_instance" : (t.firstPredictionForShape ? "first_shape" : "repeat_shape")
            let scenario=attempts[row.inputVersion]?["scenario"] ?? "external_request"
            let shape=t.predictionShapes.joined(separator:",")
            groups[scenario+"/"+warmth+"/"+shape,default:[]].append(row)
        }
        var summaries:[String:Any]=[:]
        for (key,values) in groups {
            let nonempty=values.filter{$0.status=="ok" && $0.recommendedID != nil}
            summaries[key]=["attempted":values.count,"nonempty_final":nonempty.count,
                "cancelled":values.filter{$0.status=="cancelled"}.count,"errors":values.filter{$0.status=="error"}.count,
                "empty_or_other":values.filter{$0.status != "ok" && $0.status != "cancelled" && $0.status != "error"}.count,
                "all_attempt_sdk_return":stats(values.map{$0.sdkElapsedMS}),
                "first_selectable_conditional_on_nonempty":stats(nonempty.compactMap{$0.timings.firstSDKResultMS}),
                "final_nonempty":stats(nonempty.compactMap{$0.timings.finalSDKResultMS}),
                "queue_all":stats(values.map{$0.timings.queueMS}),"parse_all":stats(values.map{$0.timings.parseMS}),
                "prediction_calls":stats(values.flatMap{$0.timings.predictions.map{$0.durationMS}}),
                "search_all":stats(values.map{$0.timings.decodeMS})]
        }
        let elapsed=finalInputNS.map{Double(now()-$0)/1_000_000}
        let object:[String:Any]=["schema":"v22-bounded-user-measurement-1","configuration":configurationLabel,
            "running":running,"stop_requested":stopping,"completed":completed,"stop_reason":stopReason.map{$0 as Any} ?? NSNull(),
            "outstanding_driver_tasks":requests.count,"records":rows,"driver_attempts":attempts.keys.sorted().map{attempts[$0]!},
            "dropped_records":snapshot.dropped,"groups":summaries,"app_times":app,"preparation_failures":snapshot.preparationFailures,
            "latest_input_catch_up_ms":catchUpMS.map{$0 as Any} ?? NSNull(),"latest_input_status":catchUpStatus,
            "latest_input_age_ms":elapsed.map{$0 as Any} ?? NSNull(),
            "sampled_process_peak_bytes":snapshot.records.flatMap{$0.preparationMemory+$0.timings.memorySamples}.map{$0.processFootprintBytes}.max().map{$0 as Any} ?? NSNull(),
            "memory_caveat":"bounded phase samples, not absolute peak or total GPU/ANE memory",
            "screen_visibility":"App supplied only; absent timestamps remain unmeasured",
            "empty_is_successful_zero_ms":false,"percentiles":"nearest rank; nonempty and all-attempt denominators separate",
            "system_cache_hits":"unknown; seen shapes are local history only","actual_compute_units":"not measured",
            "synchronous_prediction_cancel":"request marked cancelled; current synchronous call must return",
            "quality_or_latency_pass_claimed":false]
        try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
}
