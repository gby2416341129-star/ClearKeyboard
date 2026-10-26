import Foundation

/// Explicit preferences are scoped to the input that produced the menu.
/// Hiding a candidate never deletes already-entered text or the base lexicon.
@MainActor final class CandidatePreferences {
    private struct Word: Codable {
        let text: String; let reading: String; let consumed: Int
        init(_ candidate: Candidate) { text = candidate.text; reading = candidate.reading; consumed = candidate.consumed }
        var candidate: Candidate { Candidate(text: text, reading: reading, consumed: consumed, score: 4) }
    }
    private struct Rule: Codable { var pinned: Word?; var hidden: Set<String> = [] }
    private let defaults: UserDefaults
    private let storageKey = "clear.candidate.explicitPreferences.v1"
    private var rules: [String: Rule]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        rules = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: Rule].self, from: $0) } ?? [:]
    }
    private func key(_ context: KeyboardModel.CandidateContext) -> String {
        let input = context.raw.isEmpty ? String(context.before.suffix(24)) : context.raw
        return "\(context.language)-\(context.characters)-\(input)"
    }
    func applying(_ candidates: [Candidate], context: KeyboardModel.CandidateContext?) -> [Candidate] {
        guard let context, let rule = rules[key(context)] else { return candidates }
        var result = candidates.filter { !rule.hidden.contains($0.text) }
        if let pinned = rule.pinned, !rule.hidden.contains(pinned.text) {
            result.removeAll { $0.text == pinned.text }; result.insert(pinned.candidate, at: 0)
        }
        return result
    }
    func set(_ candidate: Candidate, context: KeyboardModel.CandidateContext, pinned: Bool) {
        let name = key(context); var rule = rules[name] ?? Rule()
        if pinned { rule.pinned = Word(candidate); rule.hidden.remove(candidate.text) }
        else { rule.hidden.insert(candidate.text); if rule.pinned?.text == candidate.text { rule.pinned = nil } }
        rules[name] = rule
        if rules.count > 256, let oldest = rules.keys.sorted().first(where: { $0 != name }) { rules.removeValue(forKey: oldest) }
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: storageKey) }
    }
}
