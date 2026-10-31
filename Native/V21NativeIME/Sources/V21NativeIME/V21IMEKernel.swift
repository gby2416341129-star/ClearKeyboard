import Foundation
import Dispatch
import CoreML
import CryptoKit
#if canImport(CV21IMECore)
import CV21IMECore
#endif

private func tick() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func milliseconds(_ start: UInt64, _ end: UInt64 = tick()) -> Double { Double(end - start) / 1_000_000 }
private final class V21Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    private var request: OpaquePointer?
    private var phase = "queued"
    private var cancelledPhase: String?
    private var cancelledNS: UInt64?
    private var telemetry = V21Timings()
    private var phaseNS = tick()
    private var predictionStartNS: UInt64?
    private var predictionIntervals: [(UInt64,UInt64)] = []
    private var details: [String: Any] = [:]
    func cancel(_ reason: String) { lock.lock(); defer { lock.unlock() }; if message == nil { message = reason; cancelledPhase = phase; cancelledNS = tick() }; if let request { v21_cancel_request(request) } }
    func timings() -> V21Timings { lock.lock(); defer { lock.unlock() }; return telemetry }
    func stage() -> String { lock.lock(); defer { lock.unlock() }; return phase }
    func reason() -> String? { lock.lock(); defer { lock.unlock() }; return message }
    func check() throws { if reason() != nil { throw CancellationError() } }
    func attach(_ value: OpaquePointer) { lock.lock(); defer { lock.unlock() }; request = value; if message != nil { v21_cancel_request(value) } }
    func detach() { lock.lock(); request = nil; lock.unlock() }
    func stageAgeMS() -> Double {lock.lock();defer {lock.unlock()};return milliseconds(phaseNS)}
    func predictionStageOverlap(from start: UInt64, to end: UInt64) -> Double {
        lock.lock();defer {lock.unlock()};var total:UInt64=0
        for (a,b) in predictionIntervals {let low=max(a,start),high=min(b,end);if high>low {total+=high-low}}
        if let a=predictionStartNS {let low=max(a,start);if end>low {total+=end-low}}
        return Double(total)/1_000_000
    }
    func record(_ stage: String, _ timings: V21Timings) {
        lock.lock();defer {lock.unlock()};let now=tick()
        if stage != "prediction",let start=predictionStartNS {if predictionIntervals.count<8 {predictionIntervals.append((start,now))};predictionStartNS=nil}
        if stage == "prediction",predictionStartNS==nil {predictionStartNS=now}
        phase=stage;phaseNS=now;telemetry=timings
    }
    func captureDetails(_ value: [String: Any]) { lock.lock(); details = value; lock.unlock() }
    func diagnostic() -> [String: Any] {
        lock.lock(); let p = phase, cp = cancelledPhase, cn = cancelledNS, t = telemetry, start = phaseNS, captured = details; lock.unlock()
        var result: [String: Any] = ["last_stage":p,"unfinished_stage_elapsed_ms":milliseconds(start),"captured_details":captured]
        if let cp { result["cancelled_stage"] = cp }; if let cn { result["cancelled_uptime_ns"] = cn }
        result["partial_timings"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(t))
        return result
    }
}
private struct V21Manifest: Decodable {
    let source_checkpoint_sha256: String
    let resource_binary_sha256: String
    let statistics_sha256: String
    let score_version: String
    let max_segmentations: Int
    let context_length: Int
    let maximum_target_length: Int
    let max_legal_characters: Int
}
private struct V21Vocabulary: Decodable { let syllables: [String] }
private struct V21Job: @unchecked Sendable {
    let raw: String
    let context: String
    let version: UInt64
    let generation: UInt64
    let limit: Int
    let entryNS: UInt64
    let signal: V21Cancellation
    let blocker: V21Cancellation?
    let capture: Bool
    let measurePerformance: Bool
    let diagnosticTarget: String?
    let update: (@Sendable (V21Result) -> Void)?
    let continuation: CheckedContinuation<V21Result?, Error>
}

private final class V21NativePreparation: @unchecked Sendable {
    let resources: OpaquePointer
    let syllables: [String]
    let manifest: V21Manifest
    let readMS: Double, indexMS: Double
    let memory: [V21MemorySample]
    init(directory: URL) throws {
        let begin=tick(),initialMemory=v21_process_memory_bytes()
        let manifest = try JSONDecoder().decode(V21Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("runtime_config.json")))
        let old = try Data(contentsOf: directory.appendingPathComponent("V19Resources.bin"), options: .mappedIfSafe)
        let statistics = try Data(contentsOf: directory.appendingPathComponent("V21Statistics.bin"), options: .mappedIfSafe)
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard manifest.source_checkpoint_sha256 == V21Runner.sourceSHA, digest(old) == manifest.resource_binary_sha256,
              digest(statistics) == manifest.statistics_sha256, manifest.score_version == "v21-prior-sequence-energy-1",
              manifest.max_segmentations == 8, manifest.context_length == 32,
              manifest.maximum_target_length == 64, manifest.max_legal_characters == 136 else { throw V21Error.resource("V21 resource identity/score contract mismatch") }
        let readEnd = tick()
        let words = try JSONDecoder().decode(V21Vocabulary.self, from: Data(contentsOf: directory.appendingPathComponent("vocabulary.json")))
        guard words.syllables.count == 411 else { throw V21Error.resource("Wrong syllable IDs") }
        var error = [CChar](repeating: 0, count: 1024)
        let handle = old.withUnsafeBytes { a in statistics.withUnsafeBytes { b in error.withUnsafeMutableBufferPointer { e in
            v21_resources_create(a.bindMemory(to: UInt8.self).baseAddress, a.count, b.bindMemory(to: UInt8.self).baseAddress, b.count, e.baseAddress, e.count)
        } } }
        guard let handle else { throw V21Error.resource(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        let indexEnd = tick(), indexMemory = v21_process_memory_bytes()
        self.resources=handle;self.syllables=words.syllables;self.manifest=manifest
        self.readMS=milliseconds(begin,readEnd);self.indexMS=milliseconds(readEnd,indexEnd)
        self.memory=[("prepare_entry",begin,initialMemory),("native_ready",indexEnd,indexMemory)].compactMap { phase,time,bytes in
            bytes > 0 ? V21MemorySample(phase:phase,shape:nil,uptimeNS:time,processFootprintBytes:bytes) : nil
        }
    }
    deinit { v21_resources_destroy(resources) }
}
private struct V21LoadedModel: @unchecked Sendable {
    let model: MLModel
    let units: MLComputeUnits
    let recovery: String
    let loadMS: Double
}

private final class V21Runner: @unchecked Sendable {
    static let sourceSHA = "d9d1c4974a513236d72f489d0b13f51cb6c7a94b4f2cd5d51400d314dfba80a7"
    let instanceID = UUID()
    private let native: V21NativePreparation
    var resources: OpaquePointer { native.resources }
    let model: MLModel
    let syllables: [String]
    let config: V21Configuration
    let preparation: [String: Double]
    let preparationMemory: [V21MemorySample]
    let identity: [String: String]
    private struct TensorKey: Hashable { let context:[Int32];let mask:[Int32];let pinyin:[Int32];let pinyinMask:[Int32] }
    private var tensorScores:[TensorKey:[Float]]=[:]
    private var tensorAge:[TensorKey]=[]
    private var tensorBytes=0
    private var measureCurrentJob=false
    private func cached(_ key:TensorKey) -> [Float]? {
        guard let value=tensorScores[key] else { return nil }
        tensorAge.removeAll{$0==key};tensorAge.append(key);return value
    }
    private func remember(_ value:[Float],for key:TensorKey) {
        let bytes=value.count*MemoryLayout<Float>.stride
        guard bytes<=524288 else { return }
        if let old=tensorScores.removeValue(forKey:key) { tensorBytes-=old.count*4;tensorAge.removeAll{$0==key} }
        while tensorAge.count>=16 || tensorBytes+bytes>524288 {
            guard !tensorAge.isEmpty else { break }
            if let old=tensorScores.removeValue(forKey:tensorAge.removeFirst()) { tensorBytes-=old.count*4 }
        }
        tensorScores[key]=value;tensorAge.append(key);tensorBytes+=bytes
    }
    private var hasPredicted = false // The single drain worker is its only caller.
    private var seenShapes: Set<String> = [] // B=1, T in8/16/32/64: at most4 entries.
    /// Loading compatibility only. The model graph, weights, tensors and decoder stay identical.
    private static func loadErrorDetails(_ error: Error, depth: Int = 0) -> String {
        let value = error as NSError
        var details = "[" + value.domain + ":" + String(value.code) + "] " + value.localizedDescription
        if let debug = value.userInfo[NSDebugDescriptionErrorKey] as? String { details += " | " + debug }
        if depth < 3 {
            if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
                details += " | underlying: " + loadErrorDetails(underlying, depth: depth + 1)
            }
            if let multiple = value.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] {
                for nested in multiple.prefix(3) { details += " | nested: " + loadErrorDetails(nested, depth: depth + 1) }
            }
        }
        return String(details.prefix(6000))
    }
    private static func isExecutionPlanFailure(_ error: Error, depth: Int = 0) -> Bool {
        let value = error as NSError
        if value.domain == "com.apple.CoreML", value.code == -14 { return true }
        let message = value.localizedDescription.lowercased()
        // Core ML can wrap Espresso status -14 in NSError code 0, as on the reported phone.
        if value.domain == "com.apple.CoreML", message.contains("execution plan"),
           message.contains("-14") { return true }
        if depth < 3 {
            if let nested = value.userInfo[NSUnderlyingErrorKey] as? NSError,
               isExecutionPlanFailure(nested, depth: depth + 1) { return true }
            if let errors = value.userInfo["NSMultipleUnderlyingErrors"] as? [NSError],
               errors.prefix(3).contains(where: { isExecutionPlanFailure($0, depth: depth + 1) }) { return true }
        }
        return false
    }
    private static func loadModel(_ modelURL: URL, configuration: V21Configuration) async throws -> V21LoadedModel {
        let start=tick()
        guard modelURL.pathExtension == "mlmodelc" else { throw V21Error.resource("Pass the Xcode-compiled V22 model") }
            let mlconfig = MLModelConfiguration(); mlconfig.computeUnits = configuration.computeUnits
            let loaded: MLModel
            var recovery = "not_needed"
            do {
                loaded = try await MLModel.load(contentsOf: modelURL, configuration: mlconfig)
            } catch {
                // One conditional retry of this same V22 file; no predictions, cache deletion,
                // alternative model or persistent hardware selection is performed here.
                guard (configuration.computeUnits == .cpuOnly || configuration.computeUnits == .all), Self.isExecutionPlanFailure(error) else {
                    throw V21Error.model("V22 model load failed: " + Self.loadErrorDetails(error))
                }
                let firstFailure = Self.loadErrorDetails(error)
                mlconfig.computeUnits = .cpuAndGPU
                do {
                    loaded = try await MLModel.load(contentsOf: modelURL, configuration: mlconfig)
                    recovery = "requested_" + String(describing:configuration.computeUnits) + "_execution_plan_failed; same_V22_cpuAndGPU_loaded; " + firstFailure
                } catch {
                    throw V21Error.model("V22 model could not load. Requested " + String(describing:configuration.computeUnits) + ": " + firstFailure +
                        " | Same-model CPU+GPU retry: " + Self.loadErrorDetails(error))
                }
            }
        return V21LoadedModel(model:loaded,units:mlconfig.computeUnits,recovery:recovery,loadMS:milliseconds(start))
    }
    static func prepare(modelURL: URL, directory supplied: URL?, configuration: V21Configuration) async throws -> V21Runner {
        let begin=tick(),directory:URL
        if let supplied { directory=supplied }
        else {
            #if SWIFT_PACKAGE
            guard let root=Bundle.module.resourceURL else { throw V21Error.resource("Missing package resources") }
            directory=root.appendingPathComponent("Resources",isDirectory:true)
            #else
            throw V21Error.resource("Pass the V22 resource directory for manual integration")
            #endif
        }
        async let native = Task.detached(priority:.userInitiated) {
            try autoreleasepool { try V21NativePreparation(directory:directory) }
        }.value
        async let loaded = loadModel(modelURL,configuration:configuration)
        let (tables,weights)=try await (native,loaded)
        try Task.checkCancellation()
        return try V21Runner(native:tables,loaded:weights,modelURL:modelURL,configuration:configuration,begin:begin)
    }
    private init(native: V21NativePreparation, loaded weights: V21LoadedModel, modelURL: URL,
                 configuration: V21Configuration, begin: UInt64) throws {
        let loaded=weights.model,manifest=native.manifest
            let metadata = loaded.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
            guard metadata?["checkpoint_sha256"] == Self.sourceSHA, metadata?["source_step"] == "38750",
                  metadata?["kernel_version"] == "v22_bounded_runtime", metadata?["score_version"] == manifest.score_version else { throw V21Error.model("Wrong model/compact interface") }
            for name in ["context_ids", "pinyin_ids", "context_mask", "pinyin_mask"] {
                guard let c = loaded.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint,
                      c.dataType == .int32, c.shape.count == 2 else { throw V21Error.model("Invalid input \(name)") }
            }
            for name in ["compact_legal_logits"] {
                guard loaded.modelDescription.outputDescriptionsByName[name]?.multiArrayConstraint?.dataType == .float32 else { throw V21Error.model("Missing FP32 output \(name)") }
            }
        self.native=native;self.model=loaded;self.syllables=native.syllables;self.config=configuration
        let total=milliseconds(begin)
        self.preparation=["resource_read_hash_ms":native.readMS,"native_index_ms":native.indexMS,
            "model_load_ms":weights.loadMS,"total_prepare_ms":total,
            "overlap_ms":max(0,native.readMS+native.indexMS+weights.loadMS-total)]
        var memory=native.memory
        let bytes=v21_process_memory_bytes()
        if bytes>0 { memory.append(V21MemorySample(phase:"model_loaded",shape:nil,uptimeNS:tick(),processFootprintBytes:bytes)) }
        self.preparationMemory=memory
        self.identity=["checkpoint_sha256":Self.sourceSHA,"source_step":"38750","resource_sha256":manifest.resource_binary_sha256,
            "statistics_sha256":manifest.statistics_sha256,"kernel_version":"v22_bounded_runtime","neural_source":"V19 best",
            "graph_export_version":"v22-b1-enumerated-1","SDK_version":"v22-bounded-native-1",
            "compute_units_requested":String(describing:configuration.computeUnits),"compute_units_effective_configuration":String(describing:weights.units),
            "model_load_recovery":weights.recovery,"load_adapter":"clear-v22-load-plan-recovery-1",
            "execution_adapter":"clear-v22-exact-latency-1","preparation_mode":"parallel_async",
            "score_version":manifest.score_version,"compiled_model_name":modelURL.lastPathComponent]
    }
    private func tensor(_ values: [Int32], rows: Int, width: Int) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: [NSNumber(value: rows), NSNumber(value: width)], dataType: .int32)
        let p = a.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in values.indices { p[i] = values[i] }; return a
    }
    func run(_ job: V21Job, progress: (@Sendable (V21Result) -> Void)?) throws -> V21Result {
        try job.signal.check()
        measureCurrentJob=job.capture || job.measurePerformance
        var times = job.signal.timings(); times.sdkEntryUptimeNS = job.entryNS; times.queueMS = milliseconds(job.entryNS)
        times.queueOverlapWithPreviousPredictionStageMS = job.blocker?.predictionStageOverlap(from:job.entryNS,to:tick()) ?? 0
        sampleMemory("request_start", into:&times)
        job.signal.record("parsing",times)
        let parseStart = tick()
        let input: V21Input
        do { input = try V21Input.normalize(job.raw) }
        catch { times.parseMS = milliseconds(parseStart); return empty(job, normalized: "", status: .unsupportedInput, reason: error.localizedDescription, times: times) }
        let scalars = Array(job.context.unicodeScalars.suffix(32))
        var context = [Int32](repeating: 0, count: 32), cm = context
        for (i, c) in scalars.enumerated() { context[i] = Int32(v21_character_id(resources, c.value)); cm[i] = 1 }
        let contextLast = scalars.isEmpty ? Int32(8192) : context[scalars.count-1]
        var error = [CChar](repeating: 0, count: 1024)
        let request = job.raw.withCString { raw in input.normalized.withCString { norm in input.starts.withUnsafeBufferPointer { a in input.ends.withUnsafeBufferPointer { b in error.withUnsafeMutableBufferPointer { e in
            v21_request_allocate(resources, raw, job.raw.utf8.count, norm, input.normalized.utf8.count, a.baseAddress, b.baseAddress, contextLast, config.allowIncompleteTail ? 1 : 0, job.capture ? 1 : 0, e.baseAddress, e.count)
        } } } } }
        guard let request else { throw V21Error.contract(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        job.signal.attach(request)
        defer { job.signal.detach(); v21_request_destroy(request) }
        // Attach before parsing; the cancellation lock protects destruction/detachment.
        try job.signal.check()
        guard v21_request_prepare(request) == 0 else { try job.signal.check(); throw V21Error.contract(String(cString:v21_error(request))) }
        let paths = Int(v21_path_count(request)); times.parsedPathCount=paths; times.parseMS = milliseconds(parseStart)
        job.signal.record("encoding",times)
        if paths == 0 { return empty(job, normalized: input.normalized, status: job.raw.isEmpty ? .emptyInput : .noSyllablePath, reason: "No bounded exact/completable full-pinyin path", times: times) }
        // Keep every parser path, but bound each Core ML allocation to one row.
        // Only four B/T combinations can occur; the native prior/search is unchanged.
        times.modelBatch = 1
        times.firstPredictionInThisInstance = !hasPredicted
        times.cacheState = "instance-local exact tensor logits LRU:16 entries/512KiB; decoder and receipts always fresh; CoreML cache unknown"
        // Identical context tensors are allocated once per request, not once per path.
        var contextIDs:MLMultiArray?,contextMask:MLMultiArray?
        var capturedCalls: [[String: Any]] = []
        var published = false
        for p in 0..<paths {
            try job.signal.check()
            let certified = try autoreleasepool { () throws -> Bool in
                let encodeStart = tick()
                let n = Int(v21_path_length(request, Int32(p)))
                let width = [8,16,32,64].first(where: { $0 >= n })!
                times.targetWidth = max(times.targetWidth, width)
                var py = [Int32](repeating: 0, count: width), pm = py
                for k in 0..<n { py[k] = v21_path_syllable(request, Int32(p), Int32(k)); pm[k] = 1 }
                let shapeKey="1x\(width)"
                let key=TensorKey(context:context,mask:cm,pinyin:py,pinyinMask:pm)
                let values:[Float]
                if !job.capture,let existing=cached(key) {
                    values=existing;times.tensorScoreCacheHits+=1
                    times.encodeMS+=milliseconds(encodeStart)
                } else {
                    times.tensorScoreCacheMisses+=1
                    if contextIDs==nil { contextIDs=try tensor(context,rows:1,width:32);contextMask=try tensor(cm,rows:1,width:32) }
                    let features=try MLDictionaryFeatureProvider(dictionary:[
                        "context_ids":MLFeatureValue(multiArray:contextIDs!),"context_mask":MLFeatureValue(multiArray:contextMask!),
                        "pinyin_ids":MLFeatureValue(multiArray:try tensor(py,rows:1,width:width)),
                        "pinyin_mask":MLFeatureValue(multiArray:try tensor(pm,rows:1,width:width))])
                    times.encodeMS+=milliseconds(encodeStart)
                    times.predictionShapes.append(shapeKey)
                    if job.capture {
                        capturedCalls.append(["path_index":p,"inputs":["context_ids":context,"context_mask":cm,"pinyin_ids":py,"pinyin_mask":pm],
                            "input_shapes":["context_ids":[1,32],"context_mask":[1,32],"pinyin_ids":[1,width],"pinyin_mask":[1,width]],"output_shape":[1,width,136]])
                        job.signal.captureDetails(["raw_input":job.raw,"normalized_input":input.normalized,"context_used":String(String.UnicodeScalarView(scalars)),"actual_model_calls":capturedCalls,"target_used_in_model_or_search":false])
                    }
                    try job.signal.check();times.inferenceCalls+=1;job.signal.record("prediction",times)
                    let predictStart=tick(),firstInstance = !hasPredicted,firstShape = !seenShapes.contains(shapeKey)
                    times.firstPredictionForShape=times.firstPredictionForShape || firstShape;hasPredicted=true;seenShapes.insert(shapeKey)
                    sampleMemory("before_prediction",shape:shapeKey,into:&times)
                    let output:MLFeatureProvider
                    do { output=try model.prediction(from:features) }
                    catch {
                        let duration=milliseconds(predictStart);times.predictionMS+=duration
                        times.predictions.append(V21PredictionTiming(ordinal:times.inferenceCalls,pathIndex:p,shape:shapeKey,durationMS:duration,firstInInstance:firstInstance,firstForShape:firstShape,status:"error"))
                        sampleMemory("prediction_failed",shape:shapeKey,into:&times);job.signal.record("prediction_failed",times);throw error
                    }
                    let duration=milliseconds(predictStart);times.predictionMS+=duration
                    times.predictions.append(V21PredictionTiming(ordinal:times.inferenceCalls,pathIndex:p,shape:shapeKey,durationMS:duration,firstInInstance:firstInstance,firstForShape:firstShape,status:"completed"))
                    sampleMemory("after_prediction",shape:shapeKey,into:&times);job.signal.record("decode",times);try job.signal.check()
                    guard let compact=output.featureValue(for:"compact_legal_logits")?.multiArrayValue,
                          compact.dataType == .float32,compact.shape.map({$0.intValue}) == [1,width,136] else {throw V21Error.model("Compact tensor shape/dtype mismatch")}
                    let floats=compact.dataPointer.assumingMemoryBound(to:Float.self)
                    var copy=[Float](repeating:0,count:n*136)
                    for i in 0..<n { for c in 0..<136 { copy[i*136+c]=floats[i*compact.strides[1].intValue+c*compact.strides[2].intValue] } }
                    values=copy
                    if !job.capture { remember(copy,for:key) }
                }
                try job.signal.check();job.signal.record("decode",times)
                let decodeStart=tick()
                let status=values.withUnsafeBufferPointer { a in v21_decode_path(request,Int32(p),a.baseAddress,a.count,136,1,nil,0,1) }
                times.decodeMS += milliseconds(decodeStart)
                try job.signal.check()
                job.signal.record("decode",times)
                guard status == 0 else { throw V21Error.model(String(cString: v21_error(request))) }
                if measureCurrentJob, let data = String(cString:v21_runtime_json(request)).data(using:.utf8),
                   let value = try? JSONDecoder().decode(V21CertificationSample.self,from:data) { times.certification.append(value) }
                job.signal.record("search_completed",times)
                if !job.capture,p+1<paths {
                    let exact=v21_finish_if_rank_certified(request,Int32(min(8,job.limit)))
                    guard exact>=0 else {throw V21Error.model(String(cString:v21_error(request)))}
                    if exact==1 { return true }
                }
                if let progress, !published, p+1 < paths {
                    let count = v21_snapshot(request,Int32(min(8,job.limit)),0)
                    guard count >= 0 else { throw V21Error.model(String(cString: v21_error(request))) }
                    if count > 0 {
                        times.firstCandidateReadyMS = milliseconds(job.entryNS)
                        progress(try snapshot(job, input: input, request: request, count: count, paths: paths, final: false, times: times, diagnostic: nil))
                        published = true
                    }
                }
                return false
            }
            if certified { times.scoreBoundSkippedPaths=paths-p-1;break }
        }

        let count = v21_snapshot(request,Int32(min(8,job.limit)),1)
        guard count >= 0 else { throw V21Error.model(String(cString: v21_error(request))) }
        if count > 0 && times.firstCandidateReadyMS == nil { times.firstCandidateReadyMS = milliseconds(job.entryNS) }
        var diagnostic: Data?
        if job.capture {
            let diagnosticStart = tick()
            // The target is first consulted here, after all official candidates are finalized.
            let text = job.diagnosticTarget.map { target in target.withCString { String(cString: v21_diagnostic_json(request,$0)) } } ?? String(cString: v21_diagnostic_json(request,nil))
            var object = (try JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            object["kernel_instance"] = instanceID.uuidString; object["process_id"] = ProcessInfo.processInfo.processIdentifier
            object["checkpoint_sha256"] = Self.sourceSHA; object["source_step"] = 38750; object["neural_weights_updated"] = false
            object["identity"] = identity
            object["input_version"] = job.version; object["context_used"] = String(String.UnicodeScalarView(scalars))
            object["actual_model_calls"] = capturedCalls
            object["execution_adapter"] = identity["execution_adapter"]
            object["prediction_batch_limit"] = 1
            object["full8192_partition"] = "Not computed by regular phone inference; historical Build92 domain comparison is an explicit source diagnostic"
            object["preparation_ms"] = preparation; object["compute_units_requested"] = String(describing: config.computeUnits)
            object["actual_hardware_assignment"] = "not measured"; object["screen_visible_latency"] = "requires App supplied timestamp"
            diagnostic = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            times.diagnosticPackagingMS = milliseconds(diagnosticStart)
        }
        times.finalCandidateReadyMS = milliseconds(job.entryNS)
        sampleMemory("final_candidate_ready",into:&times)
        job.signal.record("final_candidate_ready",times)
        var result = try snapshot(job,input:input,request:request,count:count,paths:paths,final:true,times:times,diagnostic:diagnostic)
        if let data = result.diagnosticData, var object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            object["api_candidates"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(result.candidates))
            object["normalization_map"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(input.map))
            result.diagnosticData = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        }
        return result
    }
    private func sampleMemory(_ phase: String, shape: String? = nil, into timings: inout V21Timings) {
        guard measureCurrentJob, timings.memorySamples.count < 24 else { return }
        let bytes = v21_process_memory_bytes()
        if bytes > 0 { timings.memorySamples.append(V21MemorySample(phase:phase,shape:shape,uptimeNS:tick(),processFootprintBytes:bytes)) }
    }
    func emit(_ job: V21Job, result: V21Result?, error: String? = nil) {
        guard job.measurePerformance, let sink=config.performanceSink else { return }
        let t=result?.timings ?? job.signal.timings()
        sink(V21PerformanceRecord(processID:ProcessInfo.processInfo.processIdentifier,instanceID:instanceID.uuidString,inputVersion:job.version,
             rawUTF8Length:job.raw.utf8.count,contextScalarLength:min(32,job.context.unicodeScalars.count),
             status:result?.status.rawValue ?? (job.signal.reason() == nil ? "error" : "cancelled"),
             cancellationReason:job.signal.reason(),error:error,stage:job.signal.stage(),unfinishedStageElapsedMS:job.signal.stageAgeMS(),pathCount:result?.syllablePathsExamined ?? t.parsedPathCount,
             completedPaths:result?.completedPaths ?? t.certification.last?.completed_paths ?? 0,recommendedID:result?.recommendedID,
             sdkElapsedMS:milliseconds(job.entryNS),timings:t,preparationMS:preparation,preparationMemory:preparationMemory,identity:identity))
    }
    private func empty(_ job: V21Job, normalized: String, status: V21ResultStatus, reason: String, times: V21Timings) -> V21Result {
        var times=times; times.finalCandidateReadyMS=milliseconds(job.entryNS); job.signal.record("empty_result",times)
        var diagnostic: Data?
        if job.capture { diagnostic = try? JSONSerialization.data(withJSONObject: ["raw_input":job.raw,"normalized_input":normalized,"status":status.rawValue,"reason":reason,"model_executed":false,"target_used_in_model_or_search":false,"checkpoint_sha256":Self.sourceSHA]) }
        return V21Result(inputVersion:job.version,rawInput:job.raw,normalizedPinyin:normalized,normalizationMap:[],candidates:[],recommendedID:nil,status:status,reason:reason,syllablePathsExamined:0,completedPaths:0,isFinal:true,previewRecommendationIsFinalRankCertified:true,requestedCount:job.limit,timings:times,generation:job.generation,instanceID:instanceID,diagnosticData:diagnostic)
    }
    private func snapshot(_ job: V21Job, input: V21Input, request: OpaquePointer, count: Int32, paths: Int, final: Bool, times: V21Timings, diagnostic: Data?) throws -> V21Result {
        let conversionStart = tick()
        var candidates: [V21Candidate] = []
        for i in 0..<count {
            let p = v21_candidate_path(request,i); var alignment: [V21Alignment] = []
            for k in 0..<v21_candidate_characters(request,i) {
                let a = Int(v21_path_start(request,p,k)), b = Int(v21_path_end(request,p,k)), pid = Int(v21_path_syllable(request,p,k))
                let range = V21Range(start:Int(input.starts[a]),end:Int(input.ends[b-1]))
                alignment.append(V21Alignment(characterUTF16Range:V21Range(start:Int(k),end:Int(k)+1),rawUTF8Range:range,rawUTF16Range:try V21Input.utf16Range(range,in:job.raw),normalizedUTF8Range:V21Range(start:a,end:b),syllable:syllables[pid]))
            }
            let suffix = String(cString:v21_path_completion(request,p))
            candidates.append(V21Candidate(id:String(cString:v21_candidate_id(request,i)),text:String(cString:v21_candidate_text(request,i)),reading:String(cString:v21_candidate_reading(request,i)),score:v21_candidate_score(request,i),consumedRawUTF8Range:V21Range(start:0,end:job.raw.utf8.count),consumedRawUTF16Range:V21Range(start:0,end:job.raw.utf16.count),fullConsumption:true,remainingPinyin:"",matchType:suffix.isEmpty ? "exact_full_pinyin" : "incomplete_tail_completion",alignment:alignment,inputVersion:job.version,pathIndex:Int(p),completionSuffix:suffix))
        }
        var measured = times; measured.candidateConversionMS = milliseconds(conversionStart)
        return V21Result(inputVersion:job.version,rawInput:job.raw,normalizedPinyin:input.normalized,normalizationMap:input.map,candidates:candidates,recommendedID:candidates.first?.id,status:candidates.isEmpty ? .noCandidateAfterConstraints : .ok,reason:candidates.isEmpty ? "No candidate survived bounded search/reading constraints" : nil,syllablePathsExamined:paths,completedPaths:Int(v21_completed_paths(request)),isFinal:final,previewRecommendationIsFinalRankCertified:true,requestedCount:job.limit,timings:measured,generation:job.generation,instanceID:instanceID,diagnosticData:diagnostic)
    }
}

/// Event-driven latest-only mailbox. One running query, one replaceable pending query.
public actor V21IMEKernel {
    private var runner: V21Runner?
    private var pending: V21Job?
    private var active: V21Cancellation?
    private var workerRunning = false
    private var generation: UInt64 = 0
    private var latestVersion: UInt64 = 0
    private var finalPublished = false
    private var publishedPaths = 0
    private var firstDeliveredMS: Double?
    private var deliveries: [[String: String]] = []
    private init(_ runner: V21Runner) { self.runner = runner }
    public static func prepare(compiledModelURL: URL, resourceDirectory: URL? = nil, configuration: V21Configuration = V21Configuration()) async throws -> V21IMEKernel {
        let runner = try await V21Runner.prepare(modelURL:compiledModelURL,directory:resourceDirectory,configuration:configuration)
        try Task.checkCancellation()
        return V21IMEKernel(runner)
    }
    public func candidates(rawPinyin: String, committedLeftContext: String, inputVersion: UInt64, requestedCount: Int = 8, onUpdate: (@Sendable (V21Result) -> Void)? = nil) async throws -> V21Result? {
        try await enqueue(raw:rawPinyin,context:committedLeftContext,version:inputVersion,limit:requestedCount,signal:V21Cancellation(),capture:false,target:nil,update:onUpdate)
    }
    /// Explicit user-triggered one-case diagnosis. It never starts a persistent logger.
    public func diagnose(rawPinyin: String, committedLeftContext: String, targetText: String? = nil, inputVersion: UInt64, onUpdate: (@Sendable (V21Result) -> Void)? = nil) async throws -> V21DiagnosticReport {
        let signal = V21Cancellation()
        do {
            let result = try await enqueue(raw:rawPinyin,context:committedLeftContext,version:inputVersion,limit:8,signal:signal,capture:true,target:targetText,update:onUpdate ?? { _ in })
            if let data = result?.diagnosticData { return V21DiagnosticReport(json:data) }
        } catch {
            let value = error as NSError
            let data = try JSONSerialization.data(withJSONObject:["status":"failed","error":error.localizedDescription,"error_domain":value.domain,"error_code":value.code,"raw_input":rawPinyin,"input_version":inputVersion,"target_used_in_model_or_search":false,"partial_evidence":signal.diagnostic()])
            return V21DiagnosticReport(json:data)
        }
        let data = try JSONSerialization.data(withJSONObject:["status":"cancelled_or_superseded","reason":signal.reason() ?? "obsolete_input_version","input_version":inputVersion,"target_used_in_model_or_search":false,"cancellation":signal.diagnostic()])
        return V21DiagnosticReport(json:data)
    }
    private func enqueue(raw: String, context: String, version: UInt64, limit: Int, signal: V21Cancellation, capture: Bool, target: String?, update: (@Sendable (V21Result) -> Void)?) async throws -> V21Result? {
        guard runner != nil else { throw V21Error.released }
        guard limit > 0 else { throw V21Error.contract("requestedCount must be positive; output is capped to8") }
        guard version >= latestVersion else { signal.cancel("older_input_version"); return nil }
        latestVersion = version; generation &+= 1; let token = generation, entry = tick()
        var queued = V21Timings(); queued.sdkEntryUptimeNS = entry; queued.waitingForPreviousPrediction = active?.stage() == "prediction"; signal.record("queued",queued)
        let blocker=active
        active?.cancel("superseded_while_running")
        if let old = pending { old.signal.cancel("superseded_before_execution"); runner?.emit(old,result:nil); old.continuation.resume(returning:nil); pending = nil }
        finalPublished = false; publishedPaths = 0; firstDeliveredMS = nil; deliveries = []
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = V21Job(raw:raw,context:context,version:version,generation:token,limit:limit,entryNS:entry,signal:signal,blocker:blocker,capture:capture,measurePerformance:runner?.config.performanceCaptureEnabled?() ?? (runner?.config.performanceSink != nil),diagnosticTarget:target,update:update,continuation:continuation)
                if !workerRunning, let runner { workerRunning = true; Task.detached(priority:.userInitiated) { await Self.drain(owner:self,runner:runner) } }
            }
        }, onCancel: { signal.cancel("caller_cancelled") })
    }
    private func takeNext() -> V21Job? {
        guard runner != nil, let job = pending else { workerRunning = false; active = nil; return nil }
        pending = nil; active = job.signal; return job
    }
    private static func drain(owner: V21IMEKernel, runner: V21Runner) async {
        while let job = await owner.takeNext() {
            do {
                let callback: (@Sendable (V21Result) -> Void)?
                if job.update != nil { callback = { snapshot in _ = Task<Void, Never> { await owner.publish(snapshot,job:job) } } }
                else { callback = nil }
                let result = try autoreleasepool { try runner.run(job,progress:callback) }
                await owner.finished(job,outcome:.success(result))
            } catch { await owner.finished(job,outcome:.failure(error)) }
        }
    }
    private func publish(_ snapshot: V21Result, job: V21Job) {
        guard runner != nil, job.signal.reason() == nil, !finalPublished, snapshot.generation == generation, snapshot.inputVersion == latestVersion, snapshot.completedPaths > publishedPaths, let update = job.update else { return }
        var value = snapshot; let elapsed = milliseconds(job.entryNS)
        if firstDeliveredMS == nil { firstDeliveredMS = elapsed }; value.timings.firstSDKResultMS = firstDeliveredMS
        publishedPaths = snapshot.completedPaths
        deliveries.append(["phase":"rank_certified_preview","completed_paths":String(snapshot.completedPaths),"recommended_id":snapshot.recommendedID ?? "","sdk_delivery_ms":String(elapsed),"candidate_ids":snapshot.candidates.map(\.id).joined(separator:",")])
        update(value)
    }
    private func finished(_ job: V21Job, outcome: Result<V21Result, Error>) {
        guard runner != nil, job.generation == generation, job.version == latestVersion, job.signal.reason() == nil else {
            runner?.emit(job,result:nil); job.continuation.resume(returning:nil); return
        }
        switch outcome {
        case .failure(let error): runner?.emit(job,result:nil,error:error.localizedDescription); job.continuation.resume(throwing:error)
        case .success(var result):
            let elapsed = milliseconds(job.entryNS); result.timings.firstSDKResultMS = firstDeliveredMS ?? elapsed; result.timings.finalSDKResultMS = elapsed; finalPublished = true
            let t = result.timings
            result.timings.otherSDKMS = max(0,elapsed-t.queueMS-t.parseMS-t.encodeMS-t.predictionMS-t.decodeMS-t.candidateConversionMS-t.diagnosticPackagingMS)
            deliveries.append(["phase":"final","completed_paths":String(result.completedPaths),"recommended_id":result.recommendedID ?? "","sdk_delivery_ms":String(elapsed),"candidate_ids":result.candidates.map(\.id).joined(separator:",")])
            if let data = result.diagnosticData, var object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                object["sdk_timings"] = (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(result.timings)))
                object["sdk_deliveries"] = deliveries
                result.diagnosticData = try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
            }
            runner?.emit(job,result:result); job.continuation.resume(returning:result)
        }
    }
    public func cancelPending() {
        generation &+= 1; active?.cancel("explicit_cancel")
        if let old = pending { old.signal.cancel("cancelled_before_execution"); runner?.emit(old,result:nil); old.continuation.resume(returning:nil); pending = nil }
    }
    public func resetComposition(inputVersion: UInt64) { latestVersion = max(latestVersion,inputVersion); cancelPending() }
    public func releaseResources() { cancelPending(); runner = nil }
    public func select(candidateID: String, from result: V21Result, prefixCharacterCount: Int? = nil) throws -> V21Selection {
        guard let runner else { throw V21Error.released }
        guard result.instanceID == runner.instanceID, result.generation == generation, result.inputVersion == latestVersion else { throw V21Error.selection("Obsolete candidate result") }
        return try result.selection(candidateID:candidateID,prefixCharacterCount:prefixCharacterCount)
    }
}
