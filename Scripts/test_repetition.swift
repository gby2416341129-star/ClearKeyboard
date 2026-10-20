import Foundation

@main struct RepetitionChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let model = try RepetitionModel(data: data)
        check(model.candidates(String(repeating: "jd", count: 8)).first?.text == String(repeating: "记得", count: 8), "Repeated word prior lost its best candidate")
        check(model.candidates(String(repeating: "hd", count: 8)).first?.text == String(repeating: "好的", count: 8), "Repeated acknowledgement changed")
        for raw in ["jd", "jdjd", "hdhd", "jtzgsm", "jdjdjdd", "jd'jd'jd", String(repeating: "jd", count: 129)] {
            check(!model.recognizes(raw), "A non-periodic, short or overlong spelling entered the repeat path")
        }
        let rows = String(data: data, encoding: .utf8)!.split(separator: "\n").filter { !$0.hasPrefix("#") }
        let codes = Set(rows.map { row in String(row.split(separator: "\t")[1].split(separator: " ").compactMap(\.first)) })
        var cases = 0
        let started = ProcessInfo.processInfo.systemUptime
        for key in codes.sorted() {
            for count in [3, 8, 64, 128] {
                let input = String(repeating: key, count: count), candidates = model.candidates(input)
                check(!candidates.isEmpty && Set(candidates.map(\.text)).count == candidates.count, "A repeat row is empty or duplicated")
                for candidate in candidates {
                    check(candidate.consumed == input.count && candidate.text.count == input.count, "A repeat candidate has the wrong commit span")
                    check(String(candidate.reading.split(separator: " ").compactMap(\.first)) == input, "A repeated word does not match its spelling")
                    check(candidate.text == String(repeating: String(candidate.text.prefix(2)), count: count), "A repetition was split into unrelated words")
                }
                cases += 1
                if count < 128 {
                    let unfinished = input + String(key.prefix(1)), partial = model.candidates(unfinished)
                    check(partial.first?.consumed == input.count && partial.first?.text == candidates.first?.text,
                          "An unfinished repeat consumed the next unit")
                    var state = Composition(); state.append(unfinished); state.consume(partial.first!.consumed)
                    check(state.raw == String(key.prefix(1)), "Partial repeat selection swallowed the remaining spelling")
                    cases += 1
                }
            }
        }
        var output: [String: Any] = ["status": "passed", "codes": codes.count, "cases": cases,
            "totalMS": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
            "jdEight": model.candidates(String(repeating: "jd", count: 8)).prefix(3).map(\.text),
            "scope": "macOS Swift release; repeat model lookup and span invariants, not iPhone latency"]
        var corrupt = data
        corrupt[0] = 0
        do { _ = try RepetitionModel(data: corrupt); fatalError("Invalid model header accepted") }
        catch { output["invalidHeaderRejected"] = true }
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
