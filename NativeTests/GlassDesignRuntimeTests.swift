import XCTest
import UIKit
@testable import ClearKeyboard

@MainActor final class GlassDesignRuntimeTests: XCTestCase {
    func testVibrationEventsAreSynchronousOrderedAndNeverQueueLatePulses() async throws {
        var received: [CGFloat] = []
        let feedback = KeyboardVibration { received.append($0) }
        feedback.prepare()
        for index in 1...200 { feedback.pulse(intensity: Double(index)/200) }
        XCTAssertEqual(received.count, 200)
        for index in 0..<200 { XCTAssertEqual(received[index], CGFloat(index+1)/200, accuracy: 0.00001) }
        feedback.pulse(intensity: 0); feedback.pulse(intensity: .nan)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(received.count, 200, "No delayed, duplicate, zero-strength or invalid pulses")
        received = []
        let key = KeyButton(key: KeyboardKey("Q"), vibration: feedback)
        var settings = KeyboardSettings(); settings.vibrationEnabled = true; settings.vibrationIntensity = 0.6823
        key.apply(settings)
        var actions = 0
        key.onAction = { _ in actions += 1; XCTAssertEqual(received.count, actions, "Exactly one synchronous impact precedes each accepted tap") }
        for _ in 0..<200 { key.sendActions(for: .touchDown); key.sendActions(for: .touchUpInside) }
        XCTAssertEqual(actions, 200); XCTAssertEqual(received.count, 200)
        key.onAction = nil
        settings.vibrationEnabled = false; key.apply(settings)
        key.sendActions(for: .touchDown); key.sendActions(for: .touchUpInside)
        XCTAssertEqual(received.count, 200, "Disabled feedback must not submit actuator events")
    }
    func testRetiredMaterialAndTapFeedbackKeysAreNotWrittenBack() throws {
        let original = KeyboardSettings()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["glass"] = "mist"; object["haptics"] = true
        let value = try JSONDecoder().decode(KeyboardSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(value, original)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String:Any])
        XCTAssertNil(saved["glass"]); XCTAssertNil(saved["haptics"])
    }
    func testVibrationSettingsSyncAndSanitizeWithoutChangingInput() throws {
        var settings = KeyboardSettings(); settings.vibrationEnabled = true; settings.vibrationIntensity = 0.6823
        var receiver = KeyboardSettings(); receiver.language = .english
        let snapshot = AppearanceSnapshot(settings: settings)
        let result = snapshot.applying(to: receiver)
        XCTAssertTrue(result.usesVibration); XCTAssertEqual(result.resolvedVibrationIntensity, 0.6823)
        XCTAssertEqual(result.language, .english)
        settings.vibrationIntensity = .infinity; settings.sanitize(); XCTAssertNil(settings.vibrationIntensity)
    }
    func testSliderAccessibilityCommitsOnlyChangedValuesAndRetainsContinuousPrecision() {
        let view = ValueSliderView(); var changes: [Double] = []
        view.configure(title: "强度", value: 0.45, range: 0...1, defaultValue: 0.45, identifier: "test", percent: true)
        view.onCommit = { changes.append($0) }
        view.slider.value = 0.6823; view.slider.sendActions(for: .valueChanged)
        view.slider.sendActions(for: .valueChanged)
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes[0], 0.6823, accuracy: 0.00001)
    }
}
