import Foundation
@preconcurrency import CoreML
import Darwin
import CryptoKit
import UIKit

enum ProbeMode: String, Codable, CaseIterable, Sendable {
    case cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all
    var title: String {
        switch self {
        case .cpuOnly: return "CPU"
        case .cpuAndGPU: return "CPU + GPU"
        case .cpuAndNeuralEngine: return "CPU + ANE（NPU）"
        case .all: return "CPU + GPU + ANE（系统调度）"
        }
    }
    var units: MLComputeUnits {
        switch self {
        case .cpuOnly: return .cpuOnly
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .all: return .all
        }
    }
}

struct NativeFailure: Codable, Sendable {
    let domain: String
    let code: Int
    let message: String
    let details: [String: String]
    let underlying: [NativeFailure]
    static func capture(_ error: Error) -> NativeFailure {
        var seen = Set<ObjectIdentifier>()
        func visit(_ error: NSError, depth: Int) -> NativeFailure {
            guard depth < 8, seen.insert(ObjectIdentifier(error)).inserted else {
                return NativeFailure(domain: error.domain, code: error.code,
                    message: "Previously captured NSError", details: [:], underlying: [])
            }
            var children: [NativeFailure] = []
            var details: [String: String] = [:]
            for (key, value) in error.userInfo {
                details[key] = String(reflecting: value)
                if let child = value as? NSError { children.append(visit(child, depth: depth + 1)) }
                if let array = value as? [NSError] {
                    children.append(contentsOf: array.map { visit($0, depth: depth + 1) })
                }
            }
            return NativeFailure(domain: error.domain, code: error.code,
                message: error.localizedDescription, details: details, underlying: children)
        }
        return visit(error as NSError, depth: 0)
    }
}

struct LatencySummary: Codable, Sendable {
    let count: Int
    let p50MS: Double
    let p95MS: Double
    let p99MS: Double
    let minimumMS: Double
    let maximumMS: Double
    let meanMS: Double
    let percentileMethod: String
    init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            sorted[max(0, min(sorted.count - 1, Int(ceil(p * Double(sorted.count))) - 1))]
        }
        count = sorted.count; p50MS = percentile(0.50); p95MS = percentile(0.95)
        p99MS = percentile(0.99); minimumMS = sorted[0]; maximumMS = sorted[sorted.count - 1]
        meanMS = values.reduce(0, +) / Double(values.count)
        percentileMethod = "nearest-rank; raw timings included"
    }
}

struct SystemSample: Codable, Sendable {
    let time: Date
    let footprintBytes: UInt64?
    let thermalState: String
    let lowPowerMode: Bool
    let processCPUSeconds: Double?
    let batteryLevel: Float?
    let batteryState: String
    static func capture(battery: Float?, batteryState: String) -> SystemSample {
        var usage = rusage()
        let cpu: Double?
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        } else { cpu = nil }
        return SystemSample(time: Date(), footprintBytes: physicalFootprint(),
            thermalState: String(describing: ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            processCPUSeconds: cpu, batteryLevel: battery, batteryState: batteryState)
    }
}

func physicalFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return code == KERN_SUCCESS ? info.phys_footprint : nil
}

final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var samples = 0
    private var timer: DispatchSourceTimer?
    func start() {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "che.v19.memory", qos: .utility))
        source.schedule(deadline: .now(), repeating: .milliseconds(20))
        source.setEventHandler { [weak self] in
            guard let self, let value = physicalFootprint() else { return }
            self.lock.lock(); self.peak = max(self.peak, value); self.samples += 1; self.lock.unlock()
        }
        timer = source; source.resume()
    }
    func stop() -> (UInt64?, Int) {
        timer?.cancel(); timer = nil
        lock.lock(); defer { lock.unlock() }
        return (samples == 0 ? nil : peak, samples)
    }
}

enum ProbeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
func elapsedMS(_ start: TimeInterval) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
func fileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func deviceMachine() -> String {
    var system = utsname(); uname(&system)
    let capacity = MemoryLayout.size(ofValue: system.machine)
    return withUnsafePointer(to: &system.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
}
