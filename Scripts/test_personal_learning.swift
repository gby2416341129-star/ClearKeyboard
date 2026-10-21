import Foundation

@main struct PersonalLearningChecks {
    static var checks = 0
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !value() { fatalError(message) }
    }
    static func composition(_ raw: String) -> Composition { var value = Composition(); value.append(raw); return value }
    static func main() throws {
        let names = [("苟博渊", "gou bo yuan"), ("陈宇涵", "chen yu han"), ("刘欣悦", "liu xin yue"),
                     ("张若曦", "zhang ruo xi"), ("欧阳明", "ou yang ming")]
        for (text, reading) in names {
            for apostrophes in [false, true] {
                let parts = reading.split(separator: " ").map(String.init)
                let raw = parts.joined(separator: apostrophes ? "'" : "")
                var draft = composition(raw), chain = PhraseLearning(), memory = PersonalLexicon()
                var before = "前文🙂" + raw, confirmed = ""
                for (character, syllable) in zip(text, parts) {
                    let choice = Candidate(text: String(character), reading: syllable, consumed: syllable.count)
                    let learned = chain.select(choice, from: draft, before: before, after: "后文", document: "field")
                    memory.record(choice, for: draft.raw)
                    draft.consume(choice.consumed); confirmed += choice.text; before = "前文🙂" + confirmed + draft.raw
                    if let learned {
                        require(draft.isEmpty && learned.raw == raw && learned.candidate.text == text, "A segmented phrase lost its original spelling")
                        memory.record(learned.candidate, for: learned.raw)
                    }
                }
                let initials = String(parts.compactMap(\.first))
                let restored = try JSONDecoder().decode(PersonalLexicon.self, from: JSONEncoder().encode(memory))
                let alias = restored.candidates(for: initials)
                require(alias.contains { $0.text == text && $0.consumed == initials.count && $0.reading == reading }, "Missing initials alias for an assembled name")
                require(restored.candidates(for: raw).contains { $0.text == text && $0.consumed == FuzzyPinyin.normalize(raw).count }, "Missing full spelling after segmented selection")
                let base = ["默认", "备选", "第三", "第四"].map { Candidate(text: $0, consumed: initials.count) }
                let merged = PersonalLexicon.merging(alias, into: base, limit: 8)
                require(merged.first?.text == "默认" && merged.prefix(4).contains { $0.text == text }, "One choice must be available without permanently pinning it")
                require(Set(merged.map(\.text)).count == merged.count, "Learning duplicated a word")
                var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(memory)) as! [String: Any]
                legacy["entries"] = (legacy["entries"] as! [[String: Any]]).map { row in var row = row; row.removeValue(forKey: "initials"); return row }
                let migrated = try JSONDecoder().decode(PersonalLexicon.self, from: JSONSerialization.data(withJSONObject: legacy))
                require(migrated.candidates(for: initials).contains { $0.text == text }, "Existing history was not upgraded to initials recall")
            }
        }
        var partial = PersonalLexicon()
        partial.record(Candidate(text: "苟", reading: "gou", consumed: 3), for: "gouboyuan")
        require(partial.candidates(for: "gby").isEmpty, "A partial character created a whole-name abbreviation")
        var chain = PhraseLearning()
        require(chain.select(Candidate(text: "苟", reading: "gou", consumed: 3), from: composition("gouboyuan"),
            before: "gouboyuan", after: "", document: "a") == nil, "An unfinished name was learned")
        let external = chain.select(Candidate(text: "博渊", reading: "bo yuan", consumed: 6), from: composition("boyuan"),
            before: "另一处boyuan", after: "", document: "b")
        require(external?.candidate.text == "博渊" && external?.raw == "boyuan", "Learning crossed a document/anchor change")
        var memory = PersonalLexicon()
        let name = Candidate(text: "陈宇涵", reading: "chen yu han", consumed: 9)
        let base = ["默认", "第二", "第三"].map { Candidate(text: $0, consumed: 3) }
        for n in 1...3 {
            memory.record(name, for: "chenyuhan")
            let values = PersonalLexicon.merging(memory.candidates(for: "cyh"), into: base, limit: 8)
            require(values[3-n].text == name.text, "Repeated confirmation did not promote gradually")
        }
        for trial in 0..<512 {
            let digits = String(format: "%08d", trial * 7919 % 100_000_000)
            var numbers = NumericLexicon(), run = NumericInputRun(), before = "前文 "
            for repetition in 1...2 {
                for digit in digits {
                    run.append(String(digit), before: before, after: "后文", document: "field"); before.append(digit)
                }
                require(run.prefix(before: before, after: "后文", document: "field") == digits, "A numeric key was lost")
                if let completed = run.complete(before: before, after: "后文", document: "field") { numbers.record(completed) }
                require(run.complete(before: before, after: "后文", document: "field") == nil, "The same run was counted twice")
                let prefix = String(digits.prefix(4)), suffix = String(digits.dropFirst(4))
                require(numbers.candidates(for: prefix).contains { $0.text == suffix } == (repetition == 2), "Numeric recall must require two complete entries")
                before += " "
            }
            let restored = try JSONDecoder().decode(NumericLexicon.self, from: JSONEncoder().encode(numbers))
            require(restored.candidates(for: String(digits.prefix(4))) == numbers.candidates(for: String(digits.prefix(4))), "Numeric persistence changed a suffix")
            require(numbers.candidates(for: digits).isEmpty && numbers.candidates(for: "１２３４").isEmpty, "Invalid or fully typed number offered a suffix")
            run.append(digits, before: "", after: "", document: "one")
            require(run.complete(before: digits, after: "", document: "two") == nil, "A number crossed documents")
        }
        var run = NumericInputRun(), before = ""
        for digit in "19981108" { run.append(String(digit), before: before, after: "", document: "f"); before.append(digit) }
        run.delete(before: before, after: "", document: "f"); before.removeLast()
        run.append("9", before: before, after: "", document: "f"); before += "9"
        require(run.complete(before: before, after: "", document: "f") == "19981109", "Deletion learned an obsolete number")
        run.append("123456", before: "99", after: "", document: "f")
        require(run.complete(before: "99123456", after: "", document: "f") == nil, "Starting in an existing number learned a fragment")
        var numbers = NumericLexicon()
        var limits = NumericLexicon()
        for value in ["1234", String(repeating: "0", count: 32)] {
            limits.record(value); limits.record(value)
            require(limits.candidates(for: String(value.prefix(3))).contains { $0.reading == value && $0.text == String(value.dropFirst(3)) }, "A valid short or long fixed number was truncated")
        }
        for value in ["12", "１２３４５６", String(repeating: "1", count: 33), "123a456"] {
            numbers.record(value); numbers.record(value)
        }
        require(numbers.candidates(for: "111").isEmpty && numbers.candidates(for: "123").isEmpty, "An invalid numeric history entry was accepted")
        print("PERSONAL_LEARNING_CHECKS " + String(data: try JSONSerialization.data(withJSONObject: ["status":"passed", "checks":checks,
            "assembledNames":names.count * 2, "numericRuns":1024, "singleChoicePinned":false, "twoCompleteNumbersRequired":true], options:[.sortedKeys]), encoding:.utf8)!)
    }
}
