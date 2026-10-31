import Foundation
import Dispatch
#if canImport(V21NativeIME)
import V21NativeIME
#endif

private final class CandidateDeliveryLease: @unchecked Sendable {
    private let lock=NSLock();private var valid=true
    let version:UInt64,input:UInt64,waitStart:UInt64,waitEnd:UInt64
    init(version:UInt64,input:UInt64,waitStart:UInt64,waitEnd:UInt64) {self.version=version;self.input=input;self.waitStart=waitStart;self.waitEnd=waitEnd}
    func invalidate(){lock.lock();valid=false;lock.unlock()}
    var isValid:Bool {lock.lock();defer{lock.unlock()};return valid}
}

/// One formal SDK/model owner per process. No UIKit work on its worker.
actor V21InputService {
    static let shared=V21InputService()
    static func startPreparing() {
        Task.detached(priority:.userInitiated) {
            do {let kernel=try await shared.prepare();await kernel.prepareFirstInputIfIdle();KernelMeasurement.shared.noteStartup("first_input_preparation_finished_or_skipped")}
            catch { /* Normal input reports preparation failure through existing UI. */ }
        }
    }
    private var initialization:Task<V21IMEKernel,Error>?
    private var version:UInt64=0
    private var delivery:CandidateDeliveryLease?
    private var measurementCaptureID:String?
    private var measurement:V22MeasurementSession?
    private var measurementTask:Task<Void,Never>?
    private var measurementRunning=false
    private var measurementStopRequested=false
    func prepare() async throws -> V21IMEKernel {
        if let initialization {return try await initialization.value}
        KernelMeasurement.shared.noteStartup("prepare_requested")
        let task=Task.detached(priority:.userInitiated) {
            guard let model=InputResources.url("V22PinyinB1FP16",extension:"mlmodelc"),
                  let config=InputResources.url("runtime_config",extension:"json",directory:"V22") else {throw V21Error.resource("V22 model/resources are unavailable")}
            return try await V21IMEKernel.prepare(compiledModelURL:model,resourceDirectory:config.deletingLastPathComponent(),configuration:V21Configuration(computeUnits:.cpuOnly,performanceSink:{KernelMeasurement.shared.receive($0)},performanceCaptureEnabled:{KernelMeasurement.shared.isRecording()}))
        }
        initialization=task
        do {let result=try await task.value;KernelMeasurement.shared.noteStartup("prepare_ready");return result}
        catch {initialization=nil;KernelMeasurement.shared.preparationFailed(error);throw error}
    }
    private static func convert(_ result:V21Result,lease:CandidateDeliveryLease,characters:Bool,returned:UInt64) throws -> V21CandidateBatch {
        guard lease.isValid else {throw CancellationError()}
        let receipts=try result.selections(prefixCharacterCount:characters ? 1:nil)
        var output:[Candidate]=[],seen=Set<String>()
        for (item,selection) in zip(result.candidates,receipts) {
            if !characters || seen.insert(selection.selectedText).inserted {
                output.append(Candidate(text:selection.selectedText,reading:selection.selectedReading,consumed:selection.consumedRawUTF16Range.length,score:item.score,nativeChoice:V21Choice(raw:result.rawInput,selection:selection,recommended:item.id == result.recommendedID,completionSuffix:item.completionSuffix)))
            }
        }
        var timing=V22AppTiming(inputVersion:lease.version,inputNS:lease.input,prepareWaitStartNS:lease.waitStart,prepareWaitEndNS:lease.waitEnd,phase:result.isFinal ? "final":"preview")
        timing.sdkReturnedNS=returned
        return V21CandidateBatch(items:output,completedPaths:result.completedPaths,isFinal:result.isFinal,timing:timing)
    }
    func candidates(raw:String,context:String,characters:Bool,inputNS:UInt64,updated:@escaping @Sendable(V21CandidateBatch)->Void) async throws -> V21CandidateBatch {
        // An already-cancelled caller must not invalidate a newer delivery.
        try Task.checkCancellation()
        guard !measurementRunning else {throw V21Error.contract("Stop manual SDK measurement before live App preview input")}
        delivery?.invalidate();version &+= 1
        let requested=version,waitStart=DispatchTime.now().uptimeNanoseconds
        let kernel=try await prepare()
        guard requested == version,!Task.isCancelled else {throw CancellationError()}
        let lease=CandidateDeliveryLease(version:requested,input:inputNS,waitStart:waitStart,waitEnd:DispatchTime.now().uptimeNanoseconds);delivery=lease
        // Convert immutable receipts directly on the SDK delivery worker. The
        // UI still validates its query/token on MainActor before accepting them.
        guard let result=try await kernel.candidates(rawPinyin:raw,committedLeftContext:context,inputVersion:requested,requestedCount:8,onUpdate:{result in
            let returned=DispatchTime.now().uptimeNanoseconds
            guard lease.isValid,let batch=try? Self.convert(result,lease:lease,characters:characters,returned:returned),lease.isValid else{return}
            updated(batch)
        }),requested == version,lease.isValid,!Task.isCancelled else {throw CancellationError()}
        return try Self.convert(result,lease:lease,characters:characters,returned:DispatchTime.now().uptimeNanoseconds)
    }
    func startMeasurement() async throws {
        guard !measurementRunning else { throw V21Error.contract("A manual measurement is already running") }
        // Mark before awaiting preparation, so a second Start cannot create a concurrent session.
        measurementRunning = true
        measurementStopRequested = false
        do {
            guard let url = InputResources.url("ordinary_probes_160", extension: "json", directory: "V22") else {
                throw V21Error.resource("Missing supplied finite measurement inputs")
            }
            let probes = try JSONDecoder().decode([V22MeasurementProbe].self, from: Data(contentsOf: url))
            guard (1...200).contains(probes.count) else { throw V21Error.contract("Invalid finite measurement count") }
            let kernel = try await prepare()
            guard !measurementStopRequested else { throw CancellationError() }
            let session = V22MeasurementSession(kernel: kernel, recorder: KernelMeasurement.shared.recorder, configurationLabel: "CPU first (.cpuOnly); effective configuration in record identity; user-started; main-App process")
            let first = version + 1; version += UInt64(probes.count)
            measurement = session; measurementCaptureID = KernelMeasurement.shared.activeSessionID()
            measurementTask = Task {
                do { try await session.run(probes: probes, firstVersion: first) }
                catch { KernelMeasurement.shared.preparationFailed(error) }
                self.measurementRunning = false
            }
        } catch { measurementRunning = false; throw error }
    }
    func stopMeasurement() async {
        measurementStopRequested = true
        measurementTask?.cancel()
        if let measurement { await measurement.stop() }
    }
    func exportMeasurement() async throws -> URL? {
        guard let measurement,measurementCaptureID == KernelMeasurement.shared.activeSessionID() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("V22-finite-session.json")
        try await measurement.export(to: url)
        return url
    }
}

struct V21CandidateBatch: Sendable {
    let items: [Candidate]
    let completedPaths: Int
    let isFinal: Bool
    var timing: V22AppTiming? = nil
}
