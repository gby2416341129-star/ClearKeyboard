import Foundation

public struct Candidate: Equatable {
    public let text: String
    public let reading: String
    public let consumed: Int
    public let score: Double
    public init(text: String, reading: String = "", consumed: Int, score: Double = 0) {
        self.text = text; self.reading = reading; self.consumed = consumed; self.score = score
    }
}
