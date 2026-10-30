import Foundation

struct LearningMemory: Codable {
    var learned: [String: Int] = [:]
    var personal = PersonalLexicon()
    var numbers = NumericLexicon()
}

/// A reset changes a single epoch pointer. A delayed writer can only update
/// its former epoch, so it can never resurrect records in the reset namespace.
enum LearningStore {
    private static func key(_ epoch: String?) -> String { "clear.learning.v3." + (epoch ?? "legacy") }
    static func load(_ defaults: UserDefaults, epoch: String?) -> LearningMemory {
        if let data = defaults.data(forKey: key(epoch)), let value = try? JSONDecoder().decode(LearningMemory.self, from: data) { return value }
        return LearningMemory(learned: defaults.dictionary(forKey: "clear.learned.v1") as? [String: Int] ?? [:],
            personal: defaults.data(forKey: "clear.choices.v2").flatMap { try? JSONDecoder().decode(PersonalLexicon.self, from: $0) } ?? PersonalLexicon(),
            numbers: defaults.data(forKey: "clear.numbers.v1").flatMap { try? JSONDecoder().decode(NumericLexicon.self, from: $0) } ?? NumericLexicon())
    }
    static func save(_ value: LearningMemory, defaults: UserDefaults, epoch: String?) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key(epoch))
    }
    static func clear(_ defaults: UserDefaults) {
        let epoch = UUID().uuidString
        save(LearningMemory(), defaults: defaults, epoch: epoch)
        defaults.set(epoch, forKey: "clear.learned.epoch")
        defaults.removeObject(forKey: "clear.input.choiceIncidents.v1")
        for name in ["clear.learned.v1", "clear.choices.v2", "clear.numbers.v1"] { defaults.removeObject(forKey: name) }
    }
}
