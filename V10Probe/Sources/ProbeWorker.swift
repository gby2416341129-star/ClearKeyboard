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

    init(bundle: Bundle, device: [String: String], outputDirectory: URL, progress: @escaping Progress) {
        self.bundle = bundle; self.progress = progress
        let order = ProbeMode.allCases.shuffled()
        let id = UUID().uuidString
        report = SuiteReport(suiteID: id, startedAt: Date(), modeOrder: order,
            results: order.map { ModeResult(mode: $0, effectiveConfiguration: $0) }, device: device)
        outputURL = outputDirectory.appendingPathComponent("v10-suite-\(id).json")
        latestURL = outputDirectory.appendingPathComponent("v10-latest.json")
    }
    func requestStop() { lock.lock(); stopRequested = true; lock.unlock() }
    private func checkStop() throws {
        lock.lock(); let stop = stopRequested; lock.unlock()
        if stop || Task.isCancelled { throw CancellationError() }
    }
    private func publish(_ phase: String, index: Int? = nil, detail: String = "") async {
        report.phase = phase
        if let index {
            report.results[index].phase = phase
            report.results[index].phaseStartedAt = Date()
            report.results[index].phaseNumber += 1
        }
        report.events.append(JournalEvent(time: Date(), mode: index.map { report.results[$0].mode.rawValue },
                                         phase: phase, detail: detail))
        await saveAndNotify()
    }
    private func saveAndNotify() async {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: outputURL, options: .atomic)
            try data.write(to: latestURL, options: .atomic)
        } catch {
            report.errors.append(NativeFailure.capture(error))
            report.phase = "记录保存失败：\(error.localizedDescription)"
        }
        await progress(report)
    }
    private func asset(_ name: String) throws -> URL {
        let url = bundle.bundleURL.appendingPathComponent("Assets").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProbeError.invalid("Missing bundled asset: \(name)")
        }
        return url
    }
    private func systemSample() async -> SystemSample {
        let battery = await MainActor.run { () -> (Float?, String) in
            let value = UIDevice.current.batteryLevel
            return (value < 0 ? nil : value, String(describing: UIDevice.current.batteryState))
        }
        return SystemSample.capture(battery: battery.0, batteryState: battery.1)
    }
    func run() async {
        await publish("准备资源", detail: "不清除系统缓存；无应用预测缓存；各配置严格独立")
        do {
            let preparation = ProcessInfo.processInfo.systemUptime
            struct ResourceManifest: Decodable {
                struct Entry: Decodable { let path: String; let sha256: String; let bytes: Int }
                let files: [Entry]
            }
            let manifest = try JSONDecoder().decode(ResourceManifest.self, from: Data(contentsOf: asset("resource_manifest.json")))
            for entry in manifest.files {
                try checkStop()
                let url = try asset(entry.path)
                let hash = try fileSHA256(url)
                guard hash == entry.sha256 else { throw ProbeError.invalid("Asset SHA256 mismatch: \(entry.path)") }
                report.resourceSHA256[entry.path] = hash
            }
            guard let modelURL = bundle.url(forResource: "V10KeyboardModel", withExtension: "mlmodelc") else {
                throw ProbeError.invalid("V10KeyboardModel.mlmodelc was not included by the iPhone build")
            }
            let encoder = try V10InputEncoder(vocabularyURL: asset("vocab.json"))
            struct Calibration: Decodable {
                let adoption_threshold: Float
                let apply_external_affine: Bool
                let adoption_logit_is_already_calibrated: Bool
            }
            let calibration = try JSONDecoder().decode(Calibration.self, from: Data(contentsOf: asset("calibration.json")))
            guard calibration.adoption_threshold == Float(0.65), !calibration.apply_external_affine,
                  calibration.adoption_logit_is_already_calibrated else { throw V10ContractError.invalidCalibration }
            let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: asset("reference_cases.json")))
            guard fixture.allCases.count == 15 else { throw ProbeError.invalid("Expected 15 original V10 reference cases") }
            var prepared: [PreparedCase] = []
            for (index, item) in fixture.allCases.enumerated() {
                try checkStop()
                var values: [String: Any] = [:]
                for (key, tensor) in item.tensors { values[key] = MLFeatureValue(multiArray: try tensor.multiArray()) }
                prepared.append(PreparedCase(source: item, provider: try MLDictionaryFeatureProvider(dictionary: values)))
                let encoded = try encoder.encode(item.request.request(revision: UInt64(index)))
                var maximumError = 0.0, integerMismatches = 0, floatMismatches = 0
                for (key, expected) in item.tensors {
                    guard let actual = encoded.arrays[key], actual.count == expected.data.count,
                          actual.shape.map({ $0.intValue }) == expected.shape else {
                        throw ProbeError.invalid("Encoder shape mismatch for \(item.caseID): \(key)")
                    }
                    for offset in expected.data.indices {
                        if expected.dtype == "int32" {
                            if actual[offset].intValue != Int(expected.data[offset]) { integerMismatches += 1 }
                        } else {
                            let error = abs(actual[offset].doubleValue - Double(Float(expected.data[offset])))
                            maximumError = max(maximumError, error)
                            if error > 0.00001 { floatMismatches += 1 }
                        }
                    }
                }
                report.inputParity.append(TensorParity(caseID: item.caseID, maximumFloatError: maximumError,
                    integerMismatches: integerMismatches, floatMismatchesAboveTolerance: floatMismatches,
                    tolerance: 0.00001))
            }
            report.resourcePreparationMS = elapsedMS(preparation)
            await publish("资源与编码检查完成", detail: "15个冻结样例；编码偏差如实记录，不换掉源输入")
            for index in report.results.indices {
                try checkStop()
                if index > 0 {
                    await publish("配置间静置 2 秒", detail: "计入总时长，不计入推理样本")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try checkStop()
                }
                await runMode(index, modelURL: modelURL, encoder: encoder, cases: prepared,
                              threshold: calibration.adoption_threshold)
                try checkStop()
            }
            await publish("核对编译模型文件完整性", detail: "计时结束后读取模型字节，避免在首次加载前预读权重")
            let compiled = try JSONDecoder().decode(ResourceManifest.self, from: Data(contentsOf: asset("compiled_model_manifest.json")))
            for entry in compiled.files {
                try checkStop()
                let hash = try fileSHA256(bundle.bundleURL.appendingPathComponent(entry.path))
                guard hash == entry.sha256 else { throw ProbeError.invalid("Compiled model SHA256 mismatch") }
                report.resourceSHA256[entry.path] = hash
            }
            report.compiledModelIntegrityVerified = true
            report.status = report.results.allSatisfy { $0.status == "completed" } ? "completed" : "completed_with_failures"
            report.finishedAt = Date()
            await publish("整轮结束，可以导出记录", detail: "完成不等于准确率验收通过；查看各配置与数值差异")
        } catch is CancellationError {
            report.status = "cancelled"; report.finishedAt = Date()
            await publish("已停止并保存，可以导出记录")
        } catch {
            report.status = "failed"; report.finishedAt = Date()
            report.errors.append(NativeFailure.capture(error))
            await publish("准备失败，错误已保存", detail: error.localizedDescription)
        }
    }

    private func runMode(_ index: Int, modelURL: URL, encoder: V10InputEncoder,
                         cases: [PreparedCase], threshold: Float) async {
        let mode = report.results[index].mode
        report.results[index].status = "running"; report.results[index].startedAt = Date()
        report.results[index].before = await systemSample()
        let sampler = MemorySampler(); sampler.start()
        var model: MLModel?
        do {
            await publish("首次加载模型", index: index, detail: mode.title + "；不自动回退计算配置")
            let config = MLModelConfiguration(); config.computeUnits = mode.units
            let loadStart = ProcessInfo.processInfo.systemUptime
            model = try MLModel(contentsOf: modelURL, configuration: config)
            report.results[index].firstModelLoadMS = elapsedMS(loadStart)
            report.results[index].footprintAfterLoad = physicalFootprint()
            try validateModel(model!)
            try checkStop()

            await publish("首次推理", index: index)
            let firstStart = ProcessInfo.processInfo.systemUptime
            let first = try prediction(model!, provider: cases[0].provider)
            report.results[index].firstPredictionMS = elapsedMS(firstStart)
            report.results[index].completedNativePredictions += 1
            report.results[index].outputChecksum += first.checksum
            try checkStop()

            await publish("15 个样例数值与决策对照", index: index)
            for item in cases {
                try checkStop()
                let comparison: OutputComparison = try autoreleasepool {
                    let result = try prediction(model!, provider: item.provider)
                    return try compare(result, with: item.source, threshold: threshold)
                }
                report.results[index].completedNativePredictions += 1
                report.results[index].comparisons.append(comparison)
            }

            await publish("预热 20 次（不混入延迟分位数）", index: index)
            for iteration in 0..<20 {
                try checkStop()
                let result = try autoreleasepool { try prediction(model!, provider: cases[iteration % cases.count].provider) }
                report.results[index].outputChecksum += result.checksum
                report.results[index].completedNativePredictions += 1
            }

            await publish("纯模型推理 0 / 600", index: index)
            for iteration in 0..<600 {
                try checkStop()
                let item = cases[iteration % cases.count]
                let measurement: (Double, Double) = try autoreleasepool {
                    let start = ProcessInfo.processInfo.systemUptime
                    let output = try model!.prediction(from: item.provider)
                    guard let scalar = output.featureValue(for: "scores")?.multiArrayValue?[0].doubleValue,
                          scalar.isFinite else { throw ProbeError.invalid("Invalid output during timed inference") }
                    return (elapsedMS(start), scalar)
                }
                report.results[index].warmedModelTimingsMS.append(measurement.0)
                report.results[index].predictionCaseIDs.append(item.source.caseID)
                report.results[index].outputChecksum += measurement.1
                report.results[index].completedNativePredictions += 1
                if (iteration + 1) % 100 == 0 {
                    report.results[index].warmSummary = LatencySummary(report.results[index].warmedModelTimingsMS)
                    await publish("纯模型推理 \(iteration + 1) / 600", index: index)
                }
            }

            await publish("完整适配调用 0 / 180", index: index)
            for iteration in 0..<180 {
                try checkStop()
                let item = cases[iteration % cases.count]
                let start = ProcessInfo.processInfo.systemUptime
                let measurement: (Double, Bool) = try autoreleasepool {
                    if V10InputEncoder.isProtected(raw: item.source.request.rawInput, mode: item.source.request.inputMode) {
                        return (0, true)
                    }
                    let encoded = try encoder.encode(item.source.request.request(revision: UInt64(iteration)))
                    var values: [String: Any] = [:]
                    for (key, value) in encoded.arrays { values[key] = MLFeatureValue(multiArray: value) }
                    let result = try prediction(model!, provider: MLDictionaryFeatureProvider(dictionary: values))
                    let count = encoded.orderedCandidateIDs.count
                    guard (0..<count).contains(result.proposal) else { throw ProbeError.invalid("Invalid proposal index") }
                    let best = (0..<count).reduce(0) { result.scores[$1] > result.scores[$0] ? $1 : $0 }
                    guard best == result.proposal else { throw ProbeError.invalid("Inconsistent proposal") }
                    let probability: Float = 1 / (1 + Float(exp(Double(-min(Float(40), max(Float(-40), result.logit))))))
                    let adopt = result.proposal != encoded.ruleIndex && probability >= threshold
                    let chosenID = adopt ? encoded.orderedCandidateIDs[result.proposal] : item.source.request.ruleID
                    return (Double(probability) + Double(chosenID.utf8.count), false)
                }
                let duration = elapsedMS(start)
                if measurement.1 { report.results[index].protectedAdapterTimingsMS.append(duration) }
                else {
                    report.results[index].adapterTimingsMS.append(duration)
                    report.results[index].adapterCaseIDs.append(item.source.caseID)
                    report.results[index].completedNativePredictions += 1
                }
                report.results[index].outputChecksum += measurement.0
                if (iteration + 1) % 60 == 0 {
                    report.results[index].adapterSummary = LatencySummary(report.results[index].adapterTimingsMS)
                    await publish("完整适配调用 \(iteration + 1) / 180", index: index)
                }
            }

            await publish("间歇调用 8 次（间隔不计入延迟）", index: index)
            for iteration in 0..<8 {
                try await Task.sleep(nanoseconds: 150_000_000)
                try checkStop()
                let start = ProcessInfo.processInfo.systemUptime
                let output = try prediction(model!, provider: cases[iteration % cases.count].provider)
                report.results[index].idleResumeTimingsMS.append(elapsedMS(start))
                report.results[index].outputChecksum += output.checksum
                report.results[index].completedNativePredictions += 1
            }
            report.results[index].idleResumeSummary = LatencySummary(report.results[index].idleResumeTimingsMS)

            await publish("同进程释放引用后再次加载", index: index,
                          detail: "框架缓存不可强制清空；不是第二次冷启动")
            model = nil
            let reloadStart = ProcessInfo.processInfo.systemUptime
            model = try MLModel(contentsOf: modelURL, configuration: config)
            report.results[index].sameProcessReloadMS = elapsedMS(reloadStart)
            let reloaded = try prediction(model!, provider: cases[0].provider)
            report.results[index].completedNativePredictions += 1
            report.results[index].outputChecksum += reloaded.checksum
            model = nil
            let memory = sampler.stop()
            report.results[index].sampledPeakFootprintBytes = memory.0
            report.results[index].memorySamples = memory.1
            try checkStop()

            await publish("读取计算分配计划（与推理分别记录）", index: index)
            report.results[index].plan = await inspectPlan(modelURL: modelURL, config: config)
            try checkStop()
            report.results[index].status = "completed"
        } catch is CancellationError {
            model = nil
            report.results[index].status = "cancelled"
        } catch {
            model = nil
            report.results[index].status = "failed"
            report.results[index].errors.append(NativeFailure.capture(error))
        }
        let remainingMemory = sampler.stop()
        if report.results[index].sampledPeakFootprintBytes == nil {
            report.results[index].sampledPeakFootprintBytes = remainingMemory.0
            report.results[index].memorySamples = remainingMemory.1
        }
        report.results[index].after = await systemSample()
        report.results[index].finishedAt = Date()
        let status = report.results[index].status
        await publish(status == "completed" ? "该配置完成" : status == "cancelled" ? "已请求停止" : "该配置失败，保留错误后继续",
                      index: index)
    }

    private func validateModel(_ model: MLModel) throws {
        let inputs = model.modelDescription.inputDescriptionsByName
        guard Set(inputs.keys) == Set(V10InputEncoder.inputShapes.keys),
              Set(model.modelDescription.outputDescriptionsByName.keys) == Set(["scores", "acceptance_logits", "proposal_index", "adopt_logit"]) else {
            throw ProbeError.invalid("Expected complete V10 eight-input/four-output graph")
        }
        for (name, expected) in V10InputEncoder.inputShapes {
            let integers = name.hasSuffix("_ids") || name == "rule_index"
            guard let constraint = inputs[name]?.multiArrayConstraint,
                  constraint.shape.map({ $0.intValue }) == expected,
                  constraint.dataType == (integers ? MLMultiArrayDataType.int32 : .float32) else {
                throw ProbeError.invalid("V10 model input contract mismatch: \(name)")
            }
        }
    }
    private struct ActualOutput {
        let scores: [Float]
        let acceptance: [Float]
        let proposal: Int
        let logit: Float
        var checksum: Double { Double(scores[0]) + Double(logit) }
    }
    private func prediction(_ model: MLModel, provider: MLFeatureProvider) throws -> ActualOutput {
        let output = try model.prediction(from: provider)
        guard let scores = output.featureValue(for: "scores")?.multiArrayValue,
              let acceptance = output.featureValue(for: "acceptance_logits")?.multiArrayValue,
              let proposal = output.featureValue(for: "proposal_index")?.multiArrayValue,
              let logit = output.featureValue(for: "adopt_logit")?.multiArrayValue,
              scores.count == 32, acceptance.count == 32, proposal.count == 1, logit.count == 1 else {
            throw ProbeError.invalid("Invalid model output shapes")
        }
        let s = (0..<32).map { scores[$0].floatValue }
        let a = (0..<32).map { acceptance[$0].floatValue }
        let z = logit[0].floatValue
        guard s.allSatisfy({ $0.isFinite }), a.allSatisfy({ $0.isFinite }), z.isFinite else {
            throw ProbeError.invalid("Non-finite model output")
        }
        return ActualOutput(scores: s, acceptance: a, proposal: proposal[0].intValue, logit: z)
    }
    private func compare(_ result: ActualOutput, with item: FixedCase, threshold: Float) throws -> OutputComparison {
        let candidates = Array(item.request.candidates.prefix(32))
        guard candidates.indices.contains(result.proposal),
              let rule = candidates.firstIndex(where: { $0.id == item.request.ruleID }),
              item.source.scores.count == 32, item.source.acceptanceLogits.count == 32,
              let sourceProposal = item.source.proposalIndex.first, let sourceLogit = item.source.adoptLogit.first else {
            throw ProbeError.invalid("Invalid source or output proposal")
        }
        let actualBest = candidates.indices.reduce(0) { result.scores[$1] > result.scores[$0] ? $1 : $0 }
        guard actualBest == result.proposal else { throw ProbeError.invalid("proposal_index differs from score argmax") }
        let protected = V10InputEncoder.isProtected(raw: item.request.rawInput, mode: item.request.inputMode)
        let probability: Float = 1 / (1 + Float(exp(Double(-min(Float(40), max(Float(-40), result.logit))))))
        let adopt = !protected && result.proposal != rule && probability >= threshold
        let selected = candidates[adopt ? result.proposal : rule]
        return OutputComparison(caseID: item.caseID,
            maximumScoreError: candidates.indices.map { abs(result.scores[$0] - item.source.scores[$0]) }.max() ?? 0,
            maximumAcceptanceError: candidates.indices.map { abs(result.acceptance[$0] - item.source.acceptanceLogits[$0]) }.max() ?? 0,
            adoptionLogitError: abs(result.logit - sourceLogit),
            proposalMatchesSource: result.proposal == sourceProposal,
            finalDecisionMatchesSource: selected.id == item.decision.finalID && adopt == item.decision.adopted,
            expectedFinalID: item.decision.finalID, actualFinalID: selected.id,
            actualProposalID: candidates[result.proposal].id, actualFinalText: selected.text,
            actualAdopted: adopt, adoptionProbability: probability,
            sourceProposalIndex: sourceProposal, actualProposalIndex: result.proposal,
            validCandidateCount: candidates.count, isProtected: protected,
            scores: result.scores, acceptanceLogits: result.acceptance, adoptLogit: result.logit)
    }

    private func inspectPlan(modelURL: URL, config: MLModelConfiguration) async -> PlanRecord {
        var record = PlanRecord(); record.status = "running"
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: config)
            guard case .program(let program) = plan.modelStructure else {
                throw ProbeError.invalid("Compute plan has no ML Program")
            }
            func deviceLabel(_ device: MLComputeDevice) -> String {
                switch device {
                case .cpu: return "CPU"
                case .gpu: return "GPU"
                case .neuralEngine: return "ANE"
                @unknown default: return "unknown"
                }
            }
            func walk(_ block: MLModelStructure.Program.Block, function: String) {
                for operation in block.operations {
                    let usage = plan.deviceUsage(for: operation)
                    let bare = operation.operatorName.split(separator: ".").last.map(String.init) ?? ""
                    let constant = bare == "const" || bare.hasPrefix("constexpr_")
                    let preferred = usage.map { deviceLabel($0.preferred) } ?? "unknown"
                    record.operations.append(OperationPlacement(function: function, operation: operation.operatorName,
                        preferred: preferred, supported: usage?.supported.map(deviceLabel) ?? [],
                        relativeCost: plan.estimatedCost(of: operation).map { Double($0.weight) }, constant: constant))
                    if !constant {
                        if preferred == "CPU" { record.plannedCPU += 1 }
                        if preferred == "GPU" { record.plannedGPU += 1 }
                        if preferred == "ANE" { record.plannedANE += 1 }
                    }
                    for nested in operation.blocks { walk(nested, function: function) }
                }
            }
            for (name, function) in program.functions { walk(function.block, function: name) }
            record.status = "completed"
        } catch {
            record.status = "failed"; record.error = NativeFailure.capture(error)
        }
        record.milliseconds = elapsedMS(start)
        return record
    }
}
