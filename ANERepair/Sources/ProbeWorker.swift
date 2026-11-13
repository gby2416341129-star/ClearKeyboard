import Foundation
@preconcurrency import CoreML
import UIKit

final class ProbeWorker: @unchecked Sendable {
    typealias Progress = @Sendable (SuiteReport) async -> Void
    private let lock=NSLock()
    private var stopped=false
    private var report:SuiteReport
    private let directory:URL
    private let progress:Progress
    init(directory:URL,device:[String:String],progress:@escaping Progress) {
        self.directory=directory;self.progress=progress
        let order=ProbeMode.allCases.shuffled()
        report=SuiteReport(suiteID:UUID().uuidString,startedAt:Date(),modeOrder:order,
                          results:order.map{ModeResult(mode:$0)},device:device)
    }
    func requestStop() { lock.lock();stopped=true;lock.unlock() }
    private func checkStop() throws {
        lock.lock();let stop=stopped;lock.unlock()
        if stop || Task.isCancelled { throw CancellationError() }
    }
    private func save(_ phase:String,index:Int?=nil) async {
        report.phase=phase
        if let index { report.results[index].phase=phase }
        do {
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601
            let data=try encoder.encode(report)
            try data.write(to:directory.appendingPathComponent("v49-\(report.suiteID).json"),options:.atomic)
            try data.write(to:directory.appendingPathComponent("v49-latest.json"),options:.atomic)
        } catch { report.errors.append(NativeFailure.capture(error)) }
        await progress(report)
    }
    private func sample() async -> SystemSample {
        let battery=await MainActor.run { (UIDevice.current.batteryLevel,String(describing:UIDevice.current.batteryState)) }
        return SystemSample.capture(battery:battery.0<0 ? nil:battery.0,batteryState:battery.1)
    }
    func run() async {
        await save("读取固定输入")
        do {
            let bundle=Bundle.main
            let asset=bundle.bundleURL.appendingPathComponent("Assets")
            let fixtureFile=try JSONDecoder().decode(ProbeFixtureFile.self,from:Data(contentsOf:asset.appendingPathComponent("fixtures.json")))
            guard fixtureFile.sourceSHA256==v49Checkpoint,!fixtureFile.cases.isEmpty,
                  let body=bundle.url(forResource:"V49PinyinANE64FP16",withExtension:"mlmodelc"),
                  let auxiliary=bundle.url(forResource:"V49InputSequenceFP16",withExtension:"mlmodelc") else {
                throw ProbeError.invalid("V49 model/input identity missing")
            }
            let providers=try fixtureFile.cases.map{try $0.provider()}
            for index in report.results.indices {
                try checkStop()
                await runMode(index,body:body,auxiliary:auxiliary,resources:asset.appendingPathComponent("Runtime"),
                              fixtures:fixtureFile.cases,providers:providers)
            }
            try checkStop()
            await save("核对编译后模型文件")
            struct Manifest:Decodable {
                struct Entry:Decodable { let path:String;let sha256:String;let bytes:Int }
                let files:[Entry]
            }
            let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:asset.appendingPathComponent("compiled_model_manifest.json")))
            for item in manifest.files {
                try checkStop()
                guard try fileSHA256(bundle.bundleURL.appendingPathComponent(item.path))==item.sha256 else {
                    throw ProbeError.invalid("Compiled model hash mismatch: \(item.path)")
                }
            }
            report.compiledModelIntegrityVerified=true
            report.status=report.results.allSatisfy{$0.status=="completed"} ? "completed":"completed_with_failures"
            report.finishedAt=Date();await save("已完成，可导出记录")
        } catch is CancellationError {
            report.status="cancelled";report.finishedAt=Date();await save("已停止，现有记录已保存")
        } catch {
            report.status="failed";report.errors.append(NativeFailure.capture(error));report.finishedAt=Date()
            await save("发生错误，仍可导出记录")
        }
    }
    private func prepare(_ index:Int,body:URL,auxiliary:URL,resources:URL) async throws -> V21IMEKernel {
        let config=V21Configuration(computeUnits:report.results[index].mode.units,allowIncompleteTail:false,
                                   performanceCaptureEnabled:{true})
        return try await V21IMEKernel.prepare(compiledModelURL:body,sequenceModelURL:auxiliary,
                                            resourceDirectory:resources,configuration:config)
    }
    private func request(_ kernel:V21IMEKernel,fixture:ProbeFixture,version:UInt64) async throws -> RequestTiming {
        var settings=V23InputSettings();settings.allowInitials=false;settings.allowTypos=false;settings.fuzzyGroups=0
        let start=ProcessInfo.processInfo.systemUptime
        guard let value=try await kernel.candidates(rawPinyin:fixture.raw,committedLeftContext:fixture.context,
                                                   inputVersion:version,inputSettings:settings),value.isFinal else {
            throw ProbeError.invalid("No final SDK response")
        }
        let duration=elapsedMS(start)
        guard value.timings.candidateResultCacheHit != true,value.timings.tensorScoreCacheHits==0 else {
            throw ProbeError.invalid("Unexpected application cache hit")
        }
        return RequestTiming(caseID:fixture.id,raw:fixture.raw,milliseconds:duration,paths:value.syllablePathsExamined,
                             candidateCount:value.candidates.count,status:value.status.rawValue,timings:value.timings)
    }
    private func bodyPrediction(_ model:MLModel,provider:MLFeatureProvider) throws -> Double {
        try autoreleasepool {
            let result=try model.prediction(from:provider)
            guard let values=result.featureValue(for:"character_logits")?.multiArrayValue,
                  values.dataType == .float32,values.shape.map({$0.intValue})==[1,8192,1,64] else {throw ProbeError.invalid("Invalid fixed64 BC1S body output")}
            return Double(values[0].floatValue)
        }
    }
    private func measure(_ index:Int,kernel:V21IMEKernel,fixtures:[ProbeFixture],providers:[MLDictionaryFeatureProvider]) async throws {
        let first=fixtures.first(where:{$0.raw=="nihao"}) ?? fixtures[0]
        await save("首次完整请求（含首次推理）",index:index)
        let firstResult=try await request(kernel,fixture:first,version:1)
        report.results[index].firstCompleteRequest=firstResult
        report.results[index].firstBodyPredictionMS=firstResult.timings.predictions.first?.durationMS
        let model=try await kernel.probeBodyModel()
        await save("预热主模型 20 次",index:index)
        for n in 0..<20 {try checkStop();_=try bodyPrediction(model,provider:providers[n%providers.count])}
        for n in 0..<300 {
            try checkStop()
            let begin=ProcessInfo.processInfo.systemUptime
            let checksum=try bodyPrediction(model,provider:providers[n%providers.count])
            let duration=elapsedMS(begin)
            report.results[index].checksum+=checksum
            report.results[index].warmedBodyMS.append(duration)
            report.results[index].warmedBodyCaseIDs.append(fixtures[n%fixtures.count].id)
            if (n+1)%50==0 {await save("主模型 \(n+1)/300",index:index)}
        }
        report.results[index].bodySummary=LatencySummary(report.results[index].warmedBodyMS)
        for n in 0..<120 {
            try checkStop()
            let value=try await request(kernel,fixture:fixtures[n%fixtures.count],version:UInt64(n+2))
            report.results[index].completeRequests.append(value)
            if (n+1)%20==0 {await save("完整解码 \(n+1)/120",index:index)}
        }
        report.results[index].completeSummary=LatencySummary(report.results[index].completeRequests.map(\.milliseconds))
        for (n,pause) in [UInt64(250_000_000),500_000_000,1_000_000_000,2_000_000_000].enumerated() {
            try checkStop();try await Task.sleep(nanoseconds:pause);try checkStop()
            report.results[index].idleRequests.append(try await request(kernel,fixture:first,version:UInt64(n+122)))
        }
    }
    private func runMode(_ index:Int,body:URL,auxiliary:URL,resources:URL,fixtures:[ProbeFixture],providers:[MLDictionaryFeatureProvider]) async {
        let sampler=MemorySampler();sampler.start()
        report.results[index].status="running";report.results[index].before=await sample()
        var kernel:V21IMEKernel?
        do {
            await save("加载 \(report.results[index].mode.title)",index:index)
            kernel=try await prepare(index,body:body,auxiliary:auxiliary,resources:resources)
            guard let active=kernel else {throw ProbeError.invalid("Missing kernel")}
            report.results[index].preparationMS=try await active.probePreparationMS()
            try await measure(index,kernel:active,fixtures:fixtures,providers:providers)
            report.results[index].status="measured"
        } catch is CancellationError {report.results[index].status="cancelled"}
        catch {report.results[index].status="failed";report.results[index].errors.append(NativeFailure.capture(error))}
        if let active=kernel {await active.releaseResources()};kernel=nil
        if report.results[index].status=="measured" {
            do {
                try checkStop();await save("释放后重新加载（系统缓存保留）",index:index)
                let reloaded=try await prepare(index,body:body,auxiliary:auxiliary,resources:resources)
                do {
                    report.results[index].reloadPreparationMS=try await reloaded.probePreparationMS()
                    report.results[index].firstRequestAfterReload=try await request(reloaded,fixture:fixtures[0],version:1)
                    await reloaded.releaseResources()
                } catch {await reloaded.releaseResources();throw error}
                report.results[index].status="completed"
            } catch is CancellationError {report.results[index].status="cancelled"}
            catch {report.results[index].status="failed";report.results[index].errors.append(NativeFailure.capture(error))}
        }
        report.results[index].after=await sample()
        let memory=sampler.stop();report.results[index].peakFootprintBytes=memory.0;report.results[index].memorySamples=memory.1
        await save("\(report.results[index].mode.title) · \(report.results[index].status)",index:index)
    }
}
