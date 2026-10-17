import XCTest
import CoreGraphics
@testable import ClearCore

final class InteractionTests: XCTestCase {
    func testAirKeyProportionsMatchTheReferenceInsteadOfOnlyFitting() {
        let height = KeyboardGeometry.preferredHeight()
        let pitch = KeyboardGeometry.rowHeight(availableHeight: height, header: KeyboardGeometry.headerHeight)
        XCTAssertEqual(pitch, 56)
        let unit = (420 - KeyboardGeometry.horizontalInset * 2) / 10
        let face = KeyboardGeometry.keyPlate(in: CGRect(x: 0, y: 0, width: unit, height: pitch))
        XCTAssertEqual(face.height, 45)
        XCTAssertEqual(pitch - face.height, 11)
        XCTAssertEqual(face.width, 35.2, accuracy: 0.01)
        XCTAssertEqual(KeyboardGeometry.horizontalInset + face.minX, 7)
    }
    func testShiftAndDeleteFacesUseNativeGapsWithoutReducingTouchTargets() {
        let unit: CGFloat = 41.2
        let hit = CGRect(x: 0, y: 0, width: unit * 1.5, height: 56)
        let shift = KeyboardGeometry.keyPlate(in: hit, action: .shift, units: 1.5)
        let delete = KeyboardGeometry.keyPlate(in: hit, action: .delete, units: 1.5)
        XCTAssertEqual(shift.width, 47.56, accuracy: 0.01)
        XCTAssertEqual(delete.width, shift.width, accuracy: 0.01)
        XCTAssertEqual(shift.minX, 3)
        XCTAssertEqual(delete.maxX, hit.maxX - 3, accuracy: 0.01)
        XCTAssertGreaterThan(hit.height, shift.height)
    }
    func testHeightCustomizationKeepsTheSameSpacingAndStandardReset() {
        for value: Double in [44, 50, 58] {
            let height = KeyboardGeometry.preferredHeight(keyHeight: value)
            let pitch = KeyboardGeometry.rowHeight(availableHeight: height, header: KeyboardGeometry.headerHeight, preferred: CGFloat(value + 6))
            XCTAssertEqual(pitch, CGFloat(value + 6))
            let face = KeyboardGeometry.keyPlate(in: CGRect(x: 0, y: 0, width: 42, height: pitch))
            XCTAssertEqual(pitch - face.height, 11)
        }
        XCTAssertEqual(KeyboardGeometry.preferredHeight(keyHeight: 50), 276)
    }
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
