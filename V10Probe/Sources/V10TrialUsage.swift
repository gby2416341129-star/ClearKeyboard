import Foundation
@preconcurrency import CoreML

// Integrate these sources into the existing keyboard-extension target.
// No App/keyboard UI is provided or changed by this delivery.
public enum V10TrialUsage {
    public static func loadOnce(bundle: Bundle, computeUnits: MLComputeUnits) async throws -> V10TrialModel {
        guard let modelURL=bundle.url(forResource:"V10KeyboardModel",withExtension:"mlmodelc",subdirectory:"Model")
                ?? bundle.url(forResource:"V10KeyboardModel",withExtension:"mlmodelc"),
              let vocabURL=bundle.url(forResource:"vocab",withExtension:"json",subdirectory:"Resources")
                ?? bundle.url(forResource:"vocab",withExtension:"json"),
              let calibrationURL=bundle.url(forResource:"calibration",withExtension:"json",subdirectory:"Resources")
                ?? bundle.url(forResource:"calibration",withExtension:"json")
        else { throw V10ContractError.invalidInput("Add the model, vocab and calibration to the KEYBOARD EXTENSION target") }
        return try await Task.detached(priority:.userInitiated) {
            try V10TrialModel(compiledModelURL:modelURL,vocabularyURL:vocabURL,
                              calibrationURL:calibrationURL,computeUnits:computeUnits)
        }.value
    }
}
// Example flow inside your existing input coordinator:
//
// 1. Startup/load once in a background task:
//      let backend = try await V10TrialUsage.loadOnce(bundle: keyboardResourceBundle,
//                                                     computeUnits: unitsChosenByHost)
//      let runner = V10LatestRequestRunner(backend: backend)
//
// 2. For actual keys/context, obtain candidates and their REAL frequency/edit-cost/
//    match-type/base-rank/consumed-range from your candidate adapter.
//    Pass that candidate snapshot plus the ACTUAL original rule-candidate ID.
//      let request = V10Request(revision: currentRevision,
//          committedContext: committedPrefix, rawInput: actualKeys, mode: .pinyin,
//          candidates: realCandidateSnapshot, ruleCandidateID: originalRuleID)
//
// 3. Return the host IME's original candidates immediately, then submit:
//      await runner.submit(request) { decision in
//          // This callback is @MainActor. Required even with runner coalescing:
//          guard decision.revision == currentInputRevision else { return }
//          // Map stable ID to the SAME candidate snapshot. Do not index a newer list.
//          applyPreferredCandidateID(decision.preferredCandidateID)
//      }
//
// 4. On context/selection/raw change increment currentInputRevision immediately.
//    Invalidate pending work with await runner.invalidate(revision: newRevision).
//    Empty candidate lists or encoding/model errors should retain the host's rule result.
//
// 5. Keep the MLModel instance. Do not load/compile the .mlpackage for each key.
//    .mlpackage compilation is handled by the existing Xcode build -> .mlmodelc.
//
// MLComputeUnits is a scheduling permission, not proof of CPU/GPU/ANE execution.
// V10's affine calibration is already in its learned policy weights.
// Never apply the historical scale/bias, legacy margin gate or a new threshold again.

