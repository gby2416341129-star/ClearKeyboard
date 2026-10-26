import CoreML
import Foundation

public struct ANEOperation: Codable, Sendable {
    public let function: String
    public let name: String
    public let preferred: String
    public let supported: [String]
    public let relativeCost: Double?
    public let constant: Bool
}

public struct ANEChunkPlan: Codable, Sendable {
    public let chunk: String
    public let operations: [ANEOperation]
    public var plannedANEOperations: Int {
        operations.filter { !$0.constant && $0.preferred == "ANE" }.count
    }
    public var computeOperations: Int { operations.filter { !$0.constant }.count }
}

/// A JSON-safe NSError graph, including the native error domains/codes and userInfo.
public struct ANEFailure: Codable, Sendable {
    public let domain: String
    public let code: Int
    public let description: String
    public let debugDescription: String
    public let userInfo: [String: String]
    public let underlying: [ANEFailure]
    public let repeatedReference: Bool

    public static func capture(_ error: Error) -> ANEFailure {
        var seen = Set<ObjectIdentifier>()
        return capture(error as NSError, seen: &seen)
    }

    private static func capture(_ error: NSError, seen: inout Set<ObjectIdentifier>) -> ANEFailure {
        let identifier = ObjectIdentifier(error)
        guard seen.insert(identifier).inserted else {
            return ANEFailure(domain: error.domain, code: error.code,
                description: "Previously recorded NSError reference",
                debugDescription: "", userInfo: [:], underlying: [], repeatedReference: true)
        }
        var details: [String: String] = [:]
        var children: [NSError] = []
        func describe(_ value: Any) -> String {
            if let child = value as? NSError {
                children.append(child)
                return "\(child.domain) (\(child.code)): \(child.localizedDescription)"
            }
            if let values = value as? [Any] {
                return "[" + values.map(describe).joined(separator: ", ") + "]"
            }
            if let values = value as? [String: Any] {
                return values.keys.sorted().map { "\($0): \(describe(values[$0]!))" }
                    .joined(separator: "\n")
            }
            return String(reflecting: value)
        }
        for key in error.userInfo.keys.sorted() {
            details[key] = describe(error.userInfo[key]!)
        }
        let underlying = children.map { capture($0, seen: &seen) }
        return ANEFailure(domain: error.domain, code: error.code,
            description: error.localizedDescription, debugDescription: error.debugDescription,
            userInfo: details, underlying: underlying, repeatedReference: false)
    }
}

/// Progress describes completed native calls; it does not imply hardware execution.
public struct ANEProgress: Codable, Sendable {
    public let phase: String
    public let model: String?
    public let index: Int?
    public let total: Int?
    public let state: String
    public let timestamp: Date
    public let elapsedMilliseconds: Double
    public let detail: String?
    public var plan: ANEChunkPlan?
    public let error: ANEFailure?

    public init(phase: String, model: String? = nil, index: Int? = nil,
                total: Int? = nil, state: String, timestamp: Date = Date(),
                elapsedMilliseconds: Double = 0, detail: String? = nil,
                plan: ANEChunkPlan? = nil, error: ANEFailure? = nil) {
        self.phase = phase
        self.model = model
        self.index = index
        self.total = total
        self.state = state
        self.timestamp = timestamp
        self.elapsedMilliseconds = elapsedMilliseconds
        self.detail = detail
        self.plan = plan
        self.error = error
    }
}

@available(iOS 18.0, macOS 15.0, *)
public enum ANEPlan {
    public static let bodyModelNames = ["chunk_a", "chunk_b", "chunk_c", "chunk_d"]

    /// This is the compiler's placement plan on THIS device, not an execution
    /// trace or ANE utilization measurement. Inspect Instruments for execution.
    /// Progress preserves completed plans even when a later model fails.
    public static func inspect(
        directory: URL, modelNames: [String] = bodyModelNames,
        continueOnFailure: Bool = false,
        onProgress: (@Sendable (ANEProgress) async -> Void)? = nil
    ) async throws -> [ANEChunkPlan] {
        try validate(modelNames)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        var results: [ANEChunkPlan] = []
        for (index, name) in modelNames.enumerated() {
            try Task.checkCancellation()
            let start = ProcessInfo.processInfo.systemUptime
            await onProgress?(ANEProgress(phase: "plan", model: name,
                index: index + 1, total: modelNames.count, state: "started"))
            var extracted: ANEChunkPlan?
            do {
                let plan = try await MLComputePlan.load(
                    contentsOf: directory.appendingPathComponent(name + ".mlmodelc"),
                    configuration: configuration)
                guard case .program(let program) = plan.modelStructure,
                      !program.functions.isEmpty else {
                    throw ANEError.invalid("No ML Program available for \(name)")
                }
                var operations: [ANEOperation] = []
                func walk(_ block: MLModelStructure.Program.Block, function: String) {
                    for operation in block.operations {
                        let usage = plan.deviceUsage(for: operation)
                        let bare = operation.operatorName.split(separator: ".").last.map(String.init) ?? ""
                        operations.append(ANEOperation(
                            function: function, name: operation.operatorName,
                            preferred: usage.map { label($0.preferred) } ?? "unknown",
                            supported: usage?.supported.map(label) ?? [],
                            relativeCost: plan.estimatedCost(of: operation).map { Double($0.weight) },
                            constant: bare == "const" || bare.hasPrefix("constexpr_")))
                        for nested in operation.blocks { walk(nested, function: function) }
                    }
                }
                for (functionName, function) in program.functions {
                    walk(function.block, function: functionName)
                }
                let result = ANEChunkPlan(chunk: name, operations: operations)
                extracted = result
                results.append(result)
                guard result.computeOperations > 0, result.plannedANEOperations > 0 else {
                    throw ANEError.invalid("\(name): no compute operation planned for ANE")
                }
                await onProgress?(ANEProgress(phase: "plan", model: name,
                    index: index + 1, total: modelNames.count, state: "succeeded",
                    elapsedMilliseconds: elapsed(since: start), plan: result))
            } catch {
                await onProgress?(ANEProgress(phase: "plan", model: name,
                    index: index + 1, total: modelNames.count, state: "failed",
                    elapsedMilliseconds: elapsed(since: start), plan: extracted,
                    error: ANEFailure.capture(error)))
                if error is CancellationError || Task.isCancelled || !continueOnFailure { throw error }
            }
        }
        return results
    }

    /// One model per background task; cancellation is checked between native calls.
    /// A synchronous Core ML compile cannot be safely interrupted or timed out.
    public static func prepare(
        packages: URL, cache: URL, modelNames: [String] = bodyModelNames,
        onProgress: (@Sendable (ANEProgress) async -> Void)? = nil
    ) async throws {
        try validate(modelNames)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for (index, name) in modelNames.enumerated() {
            try Task.checkCancellation()
            let start = ProcessInfo.processInfo.systemUptime
            await onProgress?(ANEProgress(phase: "compile", model: name,
                index: index + 1, total: modelNames.count, state: "started"))
            do {
                let work = Task.detached(priority: .userInitiated) {
                    try compileOne(name: name, packages: packages, cache: cache)
                }
                let cached = try await withTaskCancellationHandler(operation: {
                    try await work.value
                }, onCancel: { work.cancel() })
                await onProgress?(ANEProgress(phase: "compile", model: name,
                    index: index + 1, total: modelNames.count,
                    state: cached ? "cached" : "succeeded",
                    elapsedMilliseconds: elapsed(since: start)))
                try Task.checkCancellation()
            } catch {
                await onProgress?(ANEProgress(phase: "compile", model: name,
                    index: index + 1, total: modelNames.count, state: "failed",
                    elapsedMilliseconds: elapsed(since: start), error: ANEFailure.capture(error)))
                throw error
            }
        }
    }

    /// Kept for command-line callers. Call from a background Task.
    public static func compile(
        packages: URL, cache: URL, modelNames: [String] = bodyModelNames
    ) throws {
        try validate(modelNames)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for name in modelNames {
            try Task.checkCancellation()
            _ = try compileOne(name: name, packages: packages, cache: cache)
        }
    }

    private static func compileOne(name: String, packages: URL, cache: URL) throws -> Bool {
        try Task.checkCancellation()
        let manager = FileManager.default
        let destination = cache.appendingPathComponent(name + ".mlmodelc")
        if manager.fileExists(atPath: destination.path) { return true }
        let temporary = try MLModel.compileModel(
            at: packages.appendingPathComponent(name + ".mlpackage"))
        // Complete this copy even if cancellation was requested during compilation.
        try manager.copyItem(at: temporary, to: destination)
        return false
    }

    private static func validate(_ names: [String]) throws {
        guard !names.isEmpty, Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                  && !$0.contains("/") && !$0.contains("\\") }) else {
            throw ANEError.invalid("Invalid or duplicate Core ML model names")
        }
    }

    private static func elapsed(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    private static func label(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .neuralEngine: return "ANE"
        @unknown default: return "unknown"
        }
    }
}
