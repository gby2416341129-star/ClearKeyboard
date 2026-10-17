import Foundation
#if canImport(CRime)
import CRime
#endif

/// The production Chinese decoder. The C bridge serializes librime across models.
final class RimeDecoder {
    private let session: UInt
    private var previous = ""
    private var cached: [Candidate] = []
    static func bundled() throws -> RimeDecoder {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        var shared = bundle.url(forResource: "Rime", withExtension: nil)
        #if !SWIFT_PACKAGE
        if shared == nil, bundle.bundleURL.pathExtension == "appex" {
            let containingApp = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            let candidate = containingApp.appendingPathComponent("Rime", isDirectory: true)
            if containingApp.pathExtension == "app", FileManager.default.fileExists(atPath: candidate.path) { shared = candidate }
        }
        #endif
        guard let shared else { throw LexiconError.invalidFormat }
        let user = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ClearRime-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        guard cr_initialize(shared.path, user.path) != 0 else { throw LexiconError.invalidFormat }
        return try RimeDecoder()
    }
    private init() throws {
        session = cr_session()
        guard session != 0 else { throw LexiconError.invalidFormat }
    }
    deinit { cr_destroy(session) }
    func candidates(_ raw: String, cancelled: () -> Bool) -> [Candidate] {
        if raw == previous { return cached }
        guard !cancelled() else { return [] }
        let count = Int(cr_query(session, raw))
        var result: [Candidate] = [], seen = Set<String>()
        for index in 0..<count {
            if cancelled() { return [] }
            var text = [CChar](repeating: 0, count: 1_536)
            var reading = [CChar](repeating: 0, count: 1_536)
            let consumed = cr_candidate(session, Int32(index), &text, text.count, &reading, reading.count)
            let value = String(cString: text)
            if consumed > 0, !value.isEmpty, seen.insert(value).inserted {
                result.append(Candidate(text: value, reading: String(cString: reading), consumed: Int(consumed), score: 100 - Double(index)))
            }
        }
        if !cancelled() { previous = raw; cached = result }
        return result
    }
}
