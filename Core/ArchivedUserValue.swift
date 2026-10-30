import Foundation

public enum ArchivedUserValue: Codable, Sendable {
    case object([String:ArchivedUserValue]), array([ArchivedUserValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil() {self = .null}
        else if let v=try? c.decode(Bool.self) {self = .bool(v)}
        else if let v=try? c.decode(Double.self) {self = .number(v)}
        else if let v=try? c.decode(String.self) {self = .string(v)}
        else if let v=try? c.decode([String:ArchivedUserValue].self) {self = .object(v)}
        else {self = .array(try c.decode([ArchivedUserValue].self))}
    }
    public func encode(to encoder: Encoder) throws {
        var c=encoder.singleValueContainer()
        switch self {
        case .object(let v):try c.encode(v)
        case .array(let v):try c.encode(v)
        case .string(let v):try c.encode(v)
        case .number(let v):try c.encode(v)
        case .bool(let v):try c.encode(v)
        case .null:try c.encodeNil()
        }
    }
}
