import XCTest
import CoreGraphics
@testable import ClearCore

final class InteractionTests: XCTestCase {
    func testSpaceFaceAndTouchTargetStayCenteredAcrossPagesAndHandModes() throws {
        for page in [KeyboardPage.letters, .numbers, .symbols] {
            for globe in [false, true] {
                let row = try XCTUnwrap(KeyboardLayout.rows(page: page, globe: globe).last)
                let index = try XCTUnwrap(row.keys.firstIndex { $0.action == .space })
                let before = row.keys.prefix(index).reduce(0) { $0 + $1.units }
                let space = row.keys[index]
                XCTAssertEqual(before + space.units / 2, 5, accuracy: 0.0001)
                XCTAssertGreaterThanOrEqual(space.units, 4)
                for width: CGFloat in [320, 393, 420, 430] {
                    for hand in HandMode.allCases {
                        let layout = KeyboardGeometry.layout(size: CGSize(width: width, height: 276), metrics: .init(), hand: hand)
                        let hit = CGRect(x: CGFloat(before) * layout.unitWidth, y: 0, width: CGFloat(space.units) * layout.unitWidth, height: layout.rowPitch)
                        let face = KeyboardGeometry.keyPlate(in: CGRect(origin: .zero, size: hit.size), action: .space, units: space.units)
                        XCTAssertEqual(hit.midX, layout.keys.width / 2, accuracy: 0.001)
                        XCTAssertEqual(hit.minX + face.midX, layout.keys.width / 2, accuracy: 0.001)
                        XCTAssertEqual(layout.rowPitch, 56)
                    }
                }
            }
        }
    }
    func testSystemLayoutKeepsOneMainAreaAcrossHostFramesAndHandModes() {
        let metrics = KeyboardGeometry.Metrics()
        for height: CGFloat in [216, 276, 351, 472, 701, 912] {
            for hand in HandMode.allCases {
                let layout = KeyboardGeometry.layout(size: CGSize(width: 420, height: height), metrics: metrics, hand: hand)
                XCTAssertEqual(layout.rowPitch, 56)
                XCTAssertEqual(layout.keys.minY, 44)
                XCTAssertEqual(layout.keys.maxY, 276)
                XCTAssertEqual(metrics.contentHeight, 276)
                XCTAssertEqual(layout.panel.maxY, 264)
                XCTAssertEqual(layout.header.minX - layout.keys.minX, 12, accuracy: 0.01)
                if hand != .full {
                    XCTAssertGreaterThan(layout.sideRail.width, 0)
                    XCTAssertFalse(layout.sideRail.intersects(layout.keys))
                }
            }
        }
    }
    func testHorizontalInsetsAndHandednessDoNotScaleRowHeight() {
        let metrics = KeyboardGeometry.Metrics(keyHeight: 58)
        let full = KeyboardGeometry.layout(size: CGSize(width: 844, height: 380), metrics: metrics,
            leadingInset: 59, trailingInset: 59)
        let left = KeyboardGeometry.layout(size: CGSize(width: 844, height: 380), metrics: metrics,
            hand: .left, leadingInset: 59, trailingInset: 59)
        let right = KeyboardGeometry.layout(size: CGSize(width: 844, height: 380), metrics: metrics,
            hand: .right, leadingInset: 59, trailingInset: 59)
        XCTAssertEqual(full.keys.minX, 63)
        XCTAssertEqual(full.keys.maxX, 781)
        XCTAssertEqual(left.keys.minX, full.keys.minX)
        XCTAssertEqual(right.keys.maxX, full.keys.maxX)
        XCTAssertEqual(left.keys.width, right.keys.width)
        XCTAssertEqual(left.rowPitch, full.rowPitch)
        XCTAssertEqual(right.rowPitch, 64)
        let embedded = KeyboardGeometry.layout(size: CGSize(width: 320, height: 180), metrics: metrics, fitHeight: true)
        XCTAssertEqual(embedded.keys.minY + embedded.rowPitch * 4 + metrics.bottomInset, 180, accuracy: 0.01)
    }
    func testKeyboardWidthUsesHostViewportBeforeRemoteWindow() {
        XCTAssertEqual(KeyboardGeometry.fittingWidth(primary: 320, container: 420, window: 1024), 320)
        XCTAssertEqual(KeyboardGeometry.fittingWidth(primary: 0, container: 420, window: 1024), 420)
        XCTAssertEqual(KeyboardGeometry.fittingWidth(primary: .nan, container: 0, window: 420), 420)
        XCTAssertEqual(KeyboardGeometry.fittingWidth(primary: 0, container: .infinity, window: 0), 0)
        XCTAssertEqual(KeyboardGeometry.Metrics(keyHeight: .nan).contentHeight, 276)
    }
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
