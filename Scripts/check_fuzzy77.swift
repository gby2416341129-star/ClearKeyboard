import Foundation

@main enum Fuzzy77Check {
    static func main() {
        let all = Set(FuzzyPinyin.availablePairs)
        precondition(FuzzyPinyin.variants("shi", enabled: ["f/h"]) == ["shi"])
        precondition(FuzzyPinyin.variants("zhong", enabled: ["f/h"]) == ["zhong"])
        precondition(!FuzzyPinyin.variants("ang", enabled: ["an/ang"]).contains("angg"))
        precondition(FuzzyPinyin.variants("nian", enabled: all, limit: 48).contains("liang"))
        precondition(FuzzyPinyin.variants("sijiesang", enabled: all, limit: 48).contains("shijieshang"))
        precondition(Set(FuzzyPinyin.variants("shi'an", enabled: ["an/ang"])) == ["shian", "shiang"])
        let cases = ["nihao", "zhongguo", "shijie", "shangban", "mingtian", "women", "zaijian"]
        for raw in cases {
            let values = FuzzyPinyin.variants(raw, enabled: all)
            precondition(values.first == raw && values.count <= 12)
        }
        print("Fuzzy: syllable boundaries, combined pairs, explicit separators and bounded exact-first variants passed")
    }
}
