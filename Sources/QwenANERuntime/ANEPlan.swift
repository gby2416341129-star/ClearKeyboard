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

@available(iOS 18.0, macOS 15.0, *)
public enum ANEPlan {
    /// This is the compiler's placement plan on THIS device, not an execution
    /// trace or ANE utilization measurement. Inspect Instruments for execution.
    public static func inspect(directory: URL) async throws -> [ANEChunkPlan] {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        var results: [ANEChunkPlan] = []
        for suffix in ["a", "b", "c", "d"] {
            let name = "chunk_\(suffix)"
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
            for (name, function) in program.functions { walk(function.block, function: name) }
            let result = ANEChunkPlan(chunk: name, operations: operations)
            guard result.computeOperations > 0, result.plannedANEOperations > 0 else {
                throw ANEError.invalid("\(name): no compute operation planned for ANE")
            }
            results.append(result)
        }
        return results
    }

    private static func label(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .neuralEngine: return "ANE"
        @unknown default: return "unknown"
        }
    }

    /// Compile locally on the target device once; keep the portable packages
    /// separate from this OS/device's compiled cache. Call from a background Task.
    public static func compile(packages: URL, cache: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        for suffix in ["a", "b", "c", "d"] {
            try Task.checkCancellation()
            let name = "chunk_\(suffix)"
            let destination = cache.appendingPathComponent(name + ".mlmodelc")
            if manager.fileExists(atPath: destination.path) { continue }
            let temporary = try MLModel.compileModel(
                at: packages.appendingPathComponent(name + ".mlpackage"))
            try manager.copyItem(at: temporary, to: destination)
        }
    }
}
