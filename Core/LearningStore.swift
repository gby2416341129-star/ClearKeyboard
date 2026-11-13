import Foundation

struct LearningMemory: Codable {
    var learned: [String: Int] = [:]
    var personal = PersonalLexicon()
    var numbers = NumericLexicon()
    func merging(_ other:LearningMemory)->LearningMemory {
        var counts=learned
        for (key,count) in other.learned {counts[key]=max(counts[key] ?? 0,count)}
        if counts.count>512 {
            let ordered:[(key:String,value:Int)]=counts.sorted {left,right in
                if left.value != right.value {return left.value>right.value}
                return left.key<right.key
            }
            var kept:[String:Int]=[:]
            for entry in ordered.prefix(512) {kept[entry.key]=entry.value}
            counts=kept
        }
        return LearningMemory(learned:counts,personal:personal.merging(other.personal),numbers:numbers.merging(other.numbers))
    }
}

/// A reset changes a single epoch pointer. A delayed writer can only update
/// its former epoch, so it can never resurrect records in the reset namespace.
enum LearningStore {
    private static let local=NSRecursiveLock()
    private static func key(_ epoch: String?) -> String { "clear.learning.v3." + (epoch ?? "legacy") }
    static func load(_ defaults: UserDefaults, epoch: String?) -> LearningMemory {
        if let data = defaults.data(forKey: key(epoch)), let value = try? JSONDecoder().decode(LearningMemory.self, from: data) { return value }
        // An explicit epoch is an authoritative namespace, including after a
        // reset. A missing/temporarily unseen new blob must not revive legacy
        // words while another process is publishing that reset.
        guard epoch == nil else { return LearningMemory() }
        return LearningMemory(learned: defaults.dictionary(forKey: "clear.learned.v1") as? [String: Int] ?? [:],
            personal: defaults.data(forKey: "clear.choices.v2").flatMap { try? JSONDecoder().decode(PersonalLexicon.self, from: $0) } ?? PersonalLexicon(),
            numbers: defaults.data(forKey: "clear.numbers.v1").flatMap { try? JSONDecoder().decode(NumericLexicon.self, from: $0) } ?? NumericLexicon())
    }
    /// A granted shared-container URL serializes App/keyboard writers. Standard
    /// defaults retain a process-local lock and the same epoch guard.
    @discardableResult static func save(_ value: LearningMemory, defaults: UserDefaults, epoch: String?, lockURL:URL?=nil)->LearningMemory? {
        do {
            return try locked(at:lockURL) {
                _ = defaults.synchronize()
                guard defaults.string(forKey:"clear.learned.epoch")==epoch else{return nil}
                let next=load(defaults,epoch:epoch).merging(value)
                guard let data=try? JSONEncoder().encode(next),
                      defaults.string(forKey:"clear.learned.epoch")==epoch else{return nil}
                defaults.set(data,forKey:key(epoch));_ = defaults.synchronize()
                return next
            }
        } catch{return nil}
    }
    @discardableResult static func clear(_ defaults: UserDefaults,lockURL:URL?=nil)->Bool {
        do {
            return try locked(at:lockURL) {
                _ = defaults.synchronize()
                let epoch=UUID().uuidString
                guard let data=try? JSONEncoder().encode(LearningMemory()) else{return false}
                defaults.set(data,forKey:key(epoch))
                defaults.set(epoch,forKey:"clear.learned.epoch")
                defaults.removeObject(forKey:"clear.input.choiceIncidents.v1")
                for name in ["clear.learned.v1","clear.choices.v2","clear.numbers.v1"] {defaults.removeObject(forKey:name)}
                _ = defaults.synchronize()
                return true
            }
        } catch{return false}
    }
    private static func locked<T>(at url:URL?,_ body:()->T) throws->T {
        local.lock();defer{local.unlock()}
        if let url{return try SharedFileLock.perform(at:url,body)}
        return body()
    }
}
