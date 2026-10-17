import XCTest
import CoreGraphics
@testable import ClearCore

final class InteractionTests: XCTestCase {
    func testArithmeticOffersResultAndExpression() {
        XCTAssertEqual(InlineArithmetic.result(in: "99x88")?.candidates, ["8712", "99x88=8712"])
        XCTAssertEqual(InlineArithmetic.result(in: "99×88")?.value, "8712")
        XCTAssertEqual(InlineArithmetic.result(in: "99*88")?.value, "8712")
    }
    func testArithmeticPrecedenceDecimalAndParentheses() {
        XCTAssertEqual(InlineArithmetic.result(in: "2+3*4")?.value, "14")
        XCTAssertEqual(InlineArithmetic.result(in: "(2+3)*4")?.value, "20")
        XCTAssertEqual(InlineArithmetic.result(in: "1.2+2.3")?.value, "3.5")
        XCTAssertEqual(InlineArithmetic.result(in: "8÷2")?.value, "4")
        XCTAssertEqual(InlineArithmetic.result(in: "结果：-2*3")?.value, "-6")
    }
    func testInvalidOrIncompleteArithmeticHasNoCandidate() {
        for value in ["99x", "hello", "88", "1/0", "(2+3", "1..2+3", "2**3", String(repeating: "1+", count: 100)] {
            XCTAssertNil(InlineArithmetic.result(in: value), value)
        }
    }
    func testCursorRetainsFineTravelAndReverses() {
        var motion = CursorMotion()
        for _ in 0..<4 { XCTAssertEqual(motion.advance(points: 1), 0) }
        XCTAssertEqual(motion.advance(points: 1), 1)
        XCTAssertEqual(motion.advance(points: -5), -1)
        motion.reset(); XCTAssertEqual(motion.advance(points: 45), 10)
        XCTAssertEqual(motion.advance(points: .nan), 0)
    }
    func testSystemBottomAreaIsNotSubtractedTwice() {
        XCTAssertEqual(KeyboardGeometry.contentHeight(total: 351, preferred: 276), 276)
        XCTAssertEqual(KeyboardGeometry.contentHeight(total: 276, preferred: 276), 276)
        XCTAssertEqual(KeyboardGeometry.contentHeight(total: 216, preferred: 276), 216)
    }
    func testTransientHostHeightDoesNotStretchOrOverflowRows() {
        for total: CGFloat in [0, 180, 216, 276, 315, 351, 912] {
            let height = KeyboardGeometry.contentHeight(total: total, preferred: 276)
            XCTAssertLessThanOrEqual(height, 276)
            XCTAssertLessThanOrEqual(height, total)
        }
        XCTAssertEqual(KeyboardGeometry.contentHeight(total: .nan, preferred: 276), 0)
    }
}
