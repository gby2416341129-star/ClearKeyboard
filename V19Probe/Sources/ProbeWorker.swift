import Foundation
@preconcurrency import CoreML
import UIKit

final class ProbeWorker: @unchecked Sendable {
    typealias Progress = @Sendable (SuiteReport) async -> Void
    private let lock = NSLock()
    private var stopRequested = false
    private let bundle: Bundle
    private var report: SuiteReport
    private let outputURL: URL
    private let latestURL: URL
    private let progress: Progress
    init(bundle: Bundle, device: [String:String], outputDirectory: URL, progress: @escaping Progress) {
        self.bundle = bundle; self.progress = progress
        let order = ProbeMode.allCases.shuffled(), id = UUID().uuidString
        report = SuiteReport(suiteID: id, startedAt: Date(), modeOrder: order,
                             results: order.map { ModeResult(mode:$0) }, device: device)
        outputURL = outputDirectory.appendingPathComponent("v19-suite-\(id).json")
        latestURL = outputDirectory.appendingPathComponent("v19-latest.json")
    }
    func requestStop() { lock.lock(); stopRequested = true; lock.unlock() }
    private func checkStop() throws {
        lock.lock(); let stopped = stopRequested; lock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
    }
    private func publish(_ phase: String, index: Int? = nil, detail: String = "") async {
        report.phase = phase
        if let index { report.results[index].phase = phase; report.results[index].phaseStartedAt = Date() }
        report.events.append(JournalEvent(time:Date(),mode:index.map { report.results[$0].mode.rawValue },phase:phase,detail:detail))
        await saveAndNotify()
    }
    private func saveAndNotify() async {
        do {
            let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let data=try encoder.encode(report)
            try data.write(to:outputURL,options:.atomic); try data.write(to:latestURL,options:.atomic)
        } catch { report.errors.append(NativeFailure.capture(error)); report.phase="保存记录失败：\(error.localizedDescription)" }
        await progress(report)
    }
    private func asset(_ name: String) throws -> URL {
        let url=bundle.bundleURL.appendingPathComponent("Assets").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath:url.path) else { throw ProbeError.invalid("Missing asset \(name)") }
        return url
    }
    private func systemSample() async -> SystemSample {
        let battery = await MainActor.run { () -> (Float?,String) in
            let level=UIDevice.current.batteryLevel
            return (level < 0 ? nil : level,String(describing:UIDevice.current.batteryState))
        }
        return SystemSample.capture(battery:battery.0,batteryState:battery.1)
    }
    func run() async {
        await publish("准备参考输入与资源",detail:"不执行预测缓存；不预读模型权重；各计算配置独立记录")
        do {
            struct ResourceManifest: Decodable {
                struct Entry: Decodable { let path: String; let sha256: String; let bytes: Int }
                let files: [Entry]
            }
            let manifest=try JSONDecoder().decode(ResourceManifest.self,from:Data(contentsOf:asset("resource_manifest.json")))
            for item in manifest.files {
                try checkStop(); let hash=try fileSHA256(asset(item.path))
                guard hash==item.sha256 else { throw ProbeError.invalid("Resource SHA256 mismatch: \(item.path); expected=\(item.sha256), actual=\(hash)") }
                report.resourceSHA256[item.path]=hash
            }
            let fixtures=try JSONDecoder().decode(ProbeFixtureFile.self,from:Data(contentsOf:asset("fixtures.json")))
            guard fixtures.sourceSHA256==report.checkpointSHA256,!fixtures.cases.isEmpty else { throw ProbeError.invalid("Wrong V19 reference identity") }
            let providers=try fixtures.cases.map { try $0.provider() }
            guard let modelURL=bundle.url(forResource:"V19FullPinyinFP16",withExtension:"mlmodelc") else { throw ProbeError.invalid("Missing compiled V19FullPinyinFP16.mlmodelc") }
            let resourceDirectory=try asset("Runtime")
            await saveAndNotify()
            for index in report.results.indices {
                try checkStop()
                await runMode(index,modelURL:modelURL,resourceDirectory:resourceDirectory,fixtures:fixtures.cases,providers:providers)
            }
            try checkStop()
            await publish("核对编译后模型完整性",detail:"所有耗时测量完成后才读取模型文件计算SHA256")
            struct CompiledManifest: Decodable {
                struct Entry: Decodable { let path: String; let sha256: String }
                let files: [Entry]
            }
            let compiled=try JSONDecoder().decode(CompiledManifest.self,from:Data(contentsOf:asset("compiled_model_manifest.json")))
            for item in compiled.files {
                try checkStop()
                guard try fileSHA256(bundle.bundleURL.appendingPathComponent(item.path))==item.sha256 else { throw ProbeError.invalid("Compiled model hash mismatch") }
            }
            report.compiledModelIntegrityVerified=true
            report.status=report.results.allSatisfy { $0.status=="completed" } ? "completed" : "completed_with_failures"
            report.finishedAt=Date()
            await publish("本轮结束，可导出记录")
        } catch is CancellationError {
            report.status="cancelled"; report.finishedAt=Date(); await publish("已停止，现有记录已保存")
        } catch {
            report.status="failed"; report.errors.append(NativeFailure.capture(error)); report.finishedAt=Date()
            await publish("准备或完整性核对失败，仍可导出")
        }
    }
    private func runMode(_ index: Int,modelURL: URL,resourceDirectory: URL,fixtures: [ProbeFixture],providers: [MLDictionaryFeatureProvider]) async {
        let sampler=MemorySampler(); sampler.start()
        var kernel: V19IMEKernel?
        var nativeModel: MLModel?
        var version: UInt64=0
        report.results[index].status="running"; report.results[index].startedAt=Date()
        report.results[index].before=await systemSample()
        do {
            try checkStop()
            await publish("加载资源和模型 · \(report.results[index].mode.title)",index:index)
            let configuration=V19Configuration(computeUnits:report.results[index].mode.units)
            let loadStart=ProcessInfo.processInfo.systemUptime
            let prepared=try await V19IMEKernel.prepare(compiledModelURL:modelURL,resourceDirectory:resourceDirectory,configuration:configuration)
            kernel=prepared
            report.results[index].kernelPreparationMS=elapsedMS(loadStart)
            let loadTimes=try await prepared.probeLoadTimes()
            report.results[index].resourcePreparationMS=loadTimes[0]
            report.results[index].firstModelLoadMS=loadTimes[1]
            report.results[index].footprintAfterLoad=physicalFootprint()

            // The first SDK request really contains the first prediction on this
            // model instance. Do not warm the model or inspect compute plans first.
            await publish("首次完整请求（含首次推理）",index:index)
            let first=fixtures.first(where: { $0.raw=="nihao" }) ?? fixtures[0]
            version &+= 1
            let firstStart=ProcessInfo.processInfo.systemUptime
            guard let firstResult=try await prepared.candidates(rawPinyin:first.raw,committedLeftContext:first.context,inputVersion:version) else { throw ProbeError.invalid("Unexpected obsolete first request") }
            report.results[index].firstCompleteRequestMS=elapsedMS(firstStart)
            let firstCalls=try await prepared.probeLastPredictionTimes()
            report.results[index].firstRequestModelCallsMS=firstCalls
            report.results[index].firstPredictionMS=firstCalls.first
            report.results[index].firstRequestPathCount=firstResult.syllablePathsExamined
            report.results[index].completedNativePredictions += firstCalls.count
            nativeModel=try await prepared.probeLoadedModel()
            guard let model=nativeModel else { throw ProbeError.invalid("Loaded model unavailable") }

            await publish("预热单次模型 · 20次",index:index)
            for n in 0..<20 {
                try checkStop()
                _=try prediction(model,provider:providers[n % providers.count])
                report.results[index].completedNativePredictions += 1
            }
            await publish("测量单次模型 · 0/300",index:index)
            for n in 0..<300 {
                try checkStop()
                let fixtureIndex=n % providers.count
                let start=ProcessInfo.processInfo.systemUptime
                let checksum=try prediction(model,provider:providers[fixtureIndex])
                let ms=elapsedMS(start)
                report.results[index].warmedModelTimingsMS.append(ms)
                report.results[index].predictionCaseIDs.append(fixtures[fixtureIndex].id)
                report.results[index].outputChecksum += checksum
                report.results[index].completedNativePredictions += 1
                if (n+1) % 50 == 0 { await publish("测量单次模型 · \(n+1)/300",index:index) }
            }
            report.results[index].warmSummary=LatencySummary(report.results[index].warmedModelTimingsMS)

            await publish("测量完整输入内核 · 0/120",index:index)
            for n in 0..<120 {
                try checkStop()
                let fixture=fixtures[n % fixtures.count]
                version &+= 1
                let start=ProcessInfo.processInfo.systemUptime
                guard let result=try await prepared.candidates(rawPinyin:fixture.raw,committedLeftContext:fixture.context,inputVersion:version) else { throw ProbeError.invalid("Unexpected obsolete sequential SDK request") }
                let ms=elapsedMS(start)
                let calls=try await prepared.probeLastPredictionTimes()
                report.results[index].completedNativePredictions += calls.count
                report.results[index].completeRequestTimings.append(RequestTiming(caseID:fixture.id,milliseconds:ms,paths:result.syllablePathsExamined,candidateCount:result.candidates.count,status:result.status.rawValue,modelCallsMS:calls,nonPredictionWallMS:max(0,ms-calls.reduce(0,+))))
                if n < fixtures.count {
                    let expected=fixture.referenceCandidates.map(\.text), actual=result.candidates.map(\.text)
                    report.results[index].comparisons.append(FixtureComparison(caseID:fixture.id,raw:fixture.raw,context:fixture.context,expectedPaths:fixture.expectedPaths,actualPaths:result.syllablePathsExamined,referenceTop8:expected,actualTop8:actual,top1MatchesReference:expected.first==actual.first,orderedTop8MatchesReference:expected==actual,actualStatus:result.status.rawValue,scores:result.candidates.map(\.score)))
                }
                if (n+1) % 20 == 0 { await publish("测量完整输入内核 · \(n+1)/120",index:index) }
            }
            report.results[index].completeSummary=LatencySummary(report.results[index].completeRequestTimings.map(\.milliseconds))
            for count in Set(report.results[index].completeRequestTimings.map(\.paths)) {
                report.results[index].byPathCount[String(count)]=LatencySummary(report.results[index].completeRequestTimings.filter { $0.paths==count }.map(\.milliseconds))
            }

            await publish("间歇唤醒 · 4次完整请求",index:index)
            for nanoseconds in [UInt64(250_000_000),500_000_000,1_000_000_000,2_000_000_000] {
                try checkStop(); try await Task.sleep(nanoseconds:nanoseconds); try checkStop()
                version &+= 1
                let start=ProcessInfo.processInfo.systemUptime
                _=try await prepared.candidates(rawPinyin:first.raw,committedLeftContext:first.context,inputVersion:version)
                report.results[index].idleResumeTimingsMS.append(elapsedMS(start))
                report.results[index].completedNativePredictions += try await prepared.probeLastPredictionTimes().count
            }
            report.results[index].idleResumeSummary=LatencySummary(report.results[index].idleResumeTimingsMS)

            await publish("核对FP16输出与源FP32参考",index:index)
            for n in fixtures.indices {
                try checkStop()
                let values=try outputArray(model,provider:providers[n])
                var maximum=0.0, count=0, nonFinite=0
                for probe in fixtures[n].path0Probes {
                    for (character,source) in zip(probe.ids,probe.values) {
                        let value=values[[0,NSNumber(value:probe.position),NSNumber(value:character)]].floatValue
                        if value.isFinite { maximum=max(maximum,Double(abs(value-source))) } else { nonFinite += 1 }
                        count += 1
                    }
                }
                report.results[index].sourceLogitComparisons.append(SourceLogitComparison(caseID:fixtures[n].id,comparedScalarCount:count,maximumAbsoluteDifference:maximum,nonFiniteCount:nonFinite))
                report.results[index].completedNativePredictions += 1
            }

            // Release both SDK ownership and diagnostic access before reloading.
            // The `model` local above still lives to the end of this do scope, so
            // reload is performed in a separate helper after that scope below.
            await publish("本配置推理测量完成",index:index)
            report.results[index].status="measured"
        } catch is CancellationError {
            report.results[index].status="cancelled"
        } catch {
            report.results[index].status="failed"; report.results[index].errors.append(NativeFailure.capture(error))
        }
        if let active=kernel { await active.releaseResources() }; kernel=nil; nativeModel=nil
        if report.results[index].status=="measured" {
            do {
                try checkStop()
                await publish("同进程释放后重新加载",index:index,detail:"复用同一编译模型路径；系统缓存未清除")
                try await reload(index,modelURL:modelURL,resourceDirectory:resourceDirectory,fixture:fixtures.first(where: { $0.raw=="nihao" }) ?? fixtures[0])
                report.results[index].status="completed"
            } catch is CancellationError { report.results[index].status="cancelled" }
            catch { report.results[index].status="failed"; report.results[index].errors.append(NativeFailure.capture(error)) }
        }
        report.results[index].after=await systemSample()
        let memory=sampler.stop(); report.results[index].sampledPeakFootprintBytes=memory.0; report.results[index].memorySamples=memory.1
        report.results[index].finishedAt=Date()
        await publish(report.results[index].status=="completed" ? "配置完成，记录已保存" : "配置未完成，错误或停止记录已保存",index:index)
    }
    private func reload(_ index: Int,modelURL: URL,resourceDirectory: URL,fixture: ProbeFixture) async throws {
        let start=ProcessInfo.processInfo.systemUptime
        let kernel=try await V19IMEKernel.prepare(compiledModelURL:modelURL,resourceDirectory:resourceDirectory,configuration:V19Configuration(computeUnits:report.results[index].mode.units))
        report.results[index].sameProcessKernelReloadMS=elapsedMS(start)
        let times=try await kernel.probeLoadTimes(); report.results[index].sameProcessModelReloadMS=times[1]
        do {
            let first=ProcessInfo.processInfo.systemUptime
            _=try await kernel.candidates(rawPinyin:fixture.raw,committedLeftContext:fixture.context,inputVersion:1)
            report.results[index].firstCompleteRequestAfterReloadMS=elapsedMS(first)
            report.results[index].completedNativePredictions += try await kernel.probeLastPredictionTimes().count
            await kernel.releaseResources()
        } catch { await kernel.releaseResources(); throw error }
    }
    private func outputArray(_ model: MLModel,provider: MLFeatureProvider) throws -> MLMultiArray {
        let output=try model.prediction(from:provider)
        guard let array=output.featureValue(for:"character_logits")?.multiArrayValue,
              array.shape.map({$0.intValue})==[1,64,8192],array.dataType == .float32 else { throw ProbeError.invalid("Invalid V19 character_logits") }
        return array
    }
    private func prediction(_ model: MLModel,provider: MLFeatureProvider) throws -> Double {
        try autoreleasepool { Double(try outputArray(model,provider:provider)[0].floatValue) }
    }
}
