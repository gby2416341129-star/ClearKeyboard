import Foundation
import XCTest
@testable import ClearCore

final class LexiconLoadingTests: XCTestCase {
    private func dictionary() -> Data {
        // One ni -> 你 record, one e:ni index, one result ID.
        var data = Data("CLRX0001".utf8)
        for number in [UInt32(1), 1, 60, 76, 80, 89] { append(number, to: &data) }
        for number in [UInt32(0), 2, 2, 3, 0, 2, 100] { append(number, to: &data) }
        for number in [UInt32(5), 4, 0, 1, 0] { append(number, to: &data) }
        data.append(Data("ni你e:ni".utf8))
        return data
    }
    private func append(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private func replace(_ offset: Int, with value: UInt32, in data: inout Data) {
        var encoded = Data(); append(value, to: &encoded)
        data.replaceSubrange(offset..<(offset + 4), with: encoded)
    }
    private func withDictionary(_ data: Data, body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url); try body(url)
    }
    func testDemandPagedLookupMatchesEagerValidation() throws {
        try withDictionary(dictionary()) { url in
            let eager = try Lexicon(url: url), lazy = try Lexicon(url: url, validateContents: false)
            XCTAssertEqual(lazy.lookup("e:ni"), eager.lookup("e:ni"))
            XCTAssertEqual(lazy.lookup("e:ni").first?.text, "你")
            XCTAssertEqual(lazy.lookup("missing"), [])
        }
    }
    func testMalformedMappedOffsetsCannotEscapeTheirSections() throws {
        for offset in [32, 40, 48, 60, 68] {
            var bytes = dictionary(); replace(offset, with: .max, in: &bytes)
            try withDictionary(bytes) { url in
                XCTAssertThrowsError(try Lexicon(url: url))
                let lazy = try Lexicon(url: url, validateContents: false)
                XCTAssertTrue(lazy.lookup("e:ni").isEmpty)
            }
        }
        var bytes = dictionary(); replace(76, with: .max, in: &bytes)
        try withDictionary(bytes) { url in
            XCTAssertTrue(try Lexicon(url: url, validateContents: false).lookup("e:ni").isEmpty)
        }
    }
}
