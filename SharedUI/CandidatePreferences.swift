import Foundation

/// Explicit preferences are scoped to the input that produced the menu.
/// Hiding a candidate never deletes already-entered text or the base lexicon.
@MainActor final class CandidatePreferences {
    private struct Word: Codable {
        let text: String; let reading: String; let consumed: Int; var path: CandidatePath? = nil
        init(_ candidate: Candidate) { text = candidate.text; reading = candidate.reading; consumed = candidate.consumed; path = candidate.path }
        var candidate: Candidate { Candidate(text: text, reading: reading, consumed: consumed, score: 4, path: path) }
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
            let matched=result.first{$0.text==pinned.text && $0.consumed==pinned.consumed && (pinned.reading.isEmpty || $0.reading==pinned.reading)}
            // A stored path belongs to an older input/settings snapshot. Only
            // the current decoder may bind it to a nonempty draft again.
            let actual=matched ?? (context.raw.isEmpty ? pinned.candidate:nil)
            if let actual,context.raw.isEmpty || actual.canConsume(context.raw) {
                result.removeAll { $0.text == pinned.text }; result.insert(actual, at: 0)
            }
        }
        return result
    }
    func preferred(context: KeyboardModel.CandidateContext?) -> [Candidate] {
        guard let context,let pinned=rules[key(context)]?.pinned else{return []}
        return [pinned.candidate]
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
