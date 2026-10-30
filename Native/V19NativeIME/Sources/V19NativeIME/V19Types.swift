import Foundation
import CoreML

public struct V19Range: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
    public var length: Int { end - start }
}
public struct V19NormalizationUnit: Codable, Sendable {
    public let normalizedUTF8Range: V19Range
    public let originalUTF8Range: V19Range
    public let originalUTF16Range: V19Range
}
public struct V19Alignment: Codable, Sendable {
    public let characterUTF16Range: V19Range
    public let rawUTF8Range: V19Range
    public let rawUTF16Range: V19Range
    public let normalizedUTF8Range: V19Range
    public let syllable: String
}
public struct V19Candidate: Codable, Sendable {
    public let id: String
    public let text: String
    public let reading: String
    public let score: Double
    public let consumedRawUTF8Range: V19Range
    public let consumedRawUTF16Range: V19Range
    public let fullConsumption: Bool
    public let remainingPinyin: String
    public let matchType: String
    public let alignment: [V19Alignment]
    public let inputVersion: UInt64
}
public enum V19ResultStatus: String, Codable, Sendable {
    case ok, emptyInput, unsupportedInput, noCompleteSyllablePath, noCandidateAfterConstraints
}
public struct V19Result: Sendable {
    public let inputVersion: UInt64
    public let rawInput: String
    public let normalizedPinyin: String
    public let normalizationMap: [V19NormalizationUnit]
    public let candidates: [V19Candidate]
    public let recommendedID: String?
    public let status: V19ResultStatus
    public let reason: String?
    public let syllablePathsExamined: Int
    public let requestedCount: Int
    public let maximumSupportedCount: Int
    internal let generation: UInt64
    public let completedPaths: Int
    public let isFinal: Bool
}
public struct V19Selection: Sendable {
    public let inputVersion: UInt64
    public let candidateID: String
    public let selectedText: String
    public let selectedReading: String
    public let consumedRawUTF8Range: V19Range
    public let consumedRawUTF16Range: V19Range
    public let remainingPinyin: String
    public let fullConsumption: Bool
    public let alignment: [V19Alignment]
}
public enum V19Error: Error, LocalizedError {
    case resource(String), contract(String), model(String), invalidSelection(String), released
    public var errorDescription: String? {
        switch self {
        case .resource(let s), .contract(let s), .model(let s), .invalidSelection(let s): return s
        case .released: return "V19 kernel resources have been released"
        }
    }
}
public struct V19Configuration: @unchecked Sendable {
    public var computeUnits: MLComputeUnits
    public init(computeUnits: MLComputeUnits = .all) { self.computeUnits = computeUnits }
}
