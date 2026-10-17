import XCTest

@MainActor final class AppUITests: XCTestCase {
    private let clear = XCUIApplication(bundleIdentifier: "com.example.clearkeyboard")
    private func attachment(_ app: XCUIApplication, name: String) {
        let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<7 { if element.exists && element.isHittable { return }; app.swipeUp() }
    }
    func testACustomizationControlsCanBeChangedWithoutCrashing() throws {
        continueAfterFailure = false; clear.launch()
        clear.tabBars.buttons["定制"].tap()
        let segmented = clear.segmentedControls["custom.glass"]
        XCTAssertTrue(segmented.waitForExistence(timeout: 8))
        for title in ["柔雾", "纯净", "清透"] { segmented.buttons[title].tap() }
        clear.sliders["custom.opacity"].adjust(toNormalizedSliderPosition: 0.35)
        for color in ["ocean", "rose", "jade"] { clear.buttons["custom.accent." + color].tap() }
        let hex = clear.textFields["custom.hex"]; hex.tap()
        if let value = hex.value as? String { hex.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        hex.typeText("#3399FF"); clear.buttons["custom.applyHex"].tap()
        if clear.keyboards.buttons["Done"].exists { clear.keyboards.buttons["Done"].tap() }
        let height = clear.sliders["custom.keyHeight"]; reveal(height, in: clear)
        height.adjust(toNormalizedSliderPosition: 0.7); clear.buttons["custom.resetHeight"].tap()
        let hand = clear.buttons["custom.hand"]; reveal(hand, in: clear)
        for title in ["左手", "右手", "标准"] { hand.tap(); clear.buttons.matching(identifier: title).firstMatch.tap() }
        let haptics = clear.switches["custom.haptics"]; reveal(haptics, in: clear); haptics.tap(); haptics.tap()
        XCTAssertEqual(clear.state, .runningForeground)
        attachment(clear, name: "customization-controls")
    }
    private func tapSettingsText(_ label: String, in app: XCUIApplication) {
        let target = app.staticTexts.matching(identifier: label).firstMatch
        reveal(target, in: app); XCTAssertTrue(target.waitForExistence(timeout: 5), label); target.tap()
    }
    private func enableKeyboard() throws {
        clear.terminate(); XCUIDevice.shared.press(.home)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences"); settings.launch(); settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        tapSettingsText("General", in: settings)
        tapSettingsText("Keyboard", in: settings)
        // The navigation title is also “Keyboards”; select the actual settings row.
        let keyboardsRow = settings.cells.matching(identifier: "KEYBOARDS").firstMatch
        XCTAssertTrue(keyboardsRow.waitForExistence(timeout: 5)); keyboardsRow.tap()
        if !settings.staticTexts["澈"].exists {
            let add = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Add New Keyboard")).firstMatch
            if !add.waitForExistence(timeout: 20) {
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = "keyboard-settings-navigation"; screenshot.lifetime = .keepAlways; self.add(screenshot)
                let snapshot = settings.debugDescription
                let detail = XCTAttachment(string: snapshot); detail.name = "keyboard-settings-tree"; detail.lifetime = .keepAlways; self.add(detail)
                if settings.descendants(matching: .any).count < 3 {
                    throw XCTSkip("Simulator Settings exposed no keyboard-list accessibility tree; Safari extension measurement could not run")
                }
                XCTFail("Add keyboard control missing\n" + snapshot); return
            }
            add.tap()
            tapSettingsText("澈", in: settings)
        }
    }
    private func chooseKeyboard(in app: XCUIApplication) {
        let q = app.descendants(matching: .any).matching(identifier: "key.text.q").firstMatch
        for _ in 0..<6 {
            if q.waitForExistence(timeout: 2) { return }
            let globe = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Next keyboard' OR label CONTAINS[c] 'Switch keyboard' OR label CONTAINS '下一个键盘'")).firstMatch
            XCTAssertTrue(globe.exists, "System keyboard switch is missing\n" + app.debugDescription); globe.tap()
        }
        XCTFail("Clear keyboard did not appear\n" + app.debugDescription)
    }
    private func assertFullRows(in app: XCUIApplication, context: String) {
        chooseKeyboard(in: app)
        let q = app.descendants(matching: .any).matching(identifier: "key.text.q").firstMatch
        let a = app.descendants(matching: .any).matching(identifier: "key.text.a").firstMatch
        let z = app.descendants(matching: .any).matching(identifier: "key.text.z").firstMatch
        let language = app.descendants(matching: .any).matching(identifier: "key.language").firstMatch
        // Measure screen-space hit rectangles, including any host view transform.
        XCTAssertEqual(q.frame.height, 56, accuracy: 0.5, context + ": " + String(describing: q.frame))
        XCTAssertEqual(a.frame.minY - q.frame.minY, 56, accuracy: 0.5, context)
        XCTAssertEqual(z.frame.minY - a.frame.minY, 56, accuracy: 0.5, context)
        XCTAssertEqual(language.frame.minY - z.frame.minY, 56, accuracy: 0.5, context)
        XCTAssertTrue(q.isHittable && language.isHittable, context + " clipped a keyboard row")
    }
    func testBSafariSearchAndMultilineKeepFullKeyboardRows() throws {
        continueAfterFailure = false; clear.launch(); try enableKeyboard()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari"); safari.activate()
        for title in ["Continue", "Continue", "Start Browsing", "Not Now"] {
            if safari.buttons[title].waitForExistence(timeout: 2) { safari.buttons[title].tap() }
        }
        let search = safari.webViews.searchFields.matching(identifier: "Safari search size check").firstMatch
        let fallbackSearch = safari.webViews.textFields.matching(identifier: "Safari search size check").firstMatch
        let field = search.waitForExistence(timeout: 5) ? search : fallbackSearch
        XCTAssertTrue(field.waitForExistence(timeout: 8), safari.debugDescription); field.tap()
        chooseKeyboard(in: safari)
        let q = safari.descendants(matching: .any).matching(identifier: "key.text.q").firstMatch
        let z = safari.descendants(matching: .any).matching(identifier: "key.text.z").firstMatch
        let language = safari.descendants(matching: .any).matching(identifier: "key.language").firstMatch
        XCTAssertEqual(q.frame.height, 56, accuracy: 0.5, "Safari compressed the letter row: " + String(describing: q.frame))
        let a = safari.descendants(matching: .any).matching(identifier: "key.text.a").firstMatch
        XCTAssertEqual(a.frame.minY - q.frame.minY, 56, accuracy: 0.5)
        XCTAssertGreaterThan(z.frame.minY, q.frame.maxY)
        XCTAssertGreaterThanOrEqual(language.frame.minY, z.frame.maxY)
        let searchHeight = q.frame.height
        q.tap(); attachment(safari, name: "safari-search-keyboard")
        let multiline = safari.webViews.textViews.matching(identifier: "Safari multiline size check").firstMatch
        XCTAssertTrue(multiline.exists); multiline.tap(); chooseKeyboard(in: safari)
        XCTAssertEqual(q.frame.height, searchHeight, accuracy: 1)
        XCTAssertEqual(q.frame.height, 56, accuracy: 0.5)
        XCTAssertEqual(a.frame.minY - q.frame.minY, 56, accuracy: 0.5)
        attachment(safari, name: "safari-multiline-keyboard")
        // The address bar uses different input traits from a webpage search field.
        let address = safari.textFields.matching(NSPredicate(format: "identifier == 'URL' OR label CONTAINS[c] 'Address'")).firstMatch
        if address.exists && address.isHittable { address.tap() }
        else {
            let location = safari.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'URL' OR label == 'Address' OR label == 'Search or enter website name' OR (elementType == 9 AND label CONTAINS '127.0.0.1')")).firstMatch
            XCTAssertTrue(location.waitForExistence(timeout: 5), "Address bar missing\n" + safari.debugDescription)
            location.tap()
        }
        assertFullRows(in: safari, context: "Safari address bar")
        let cancel = safari.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
        else {
            let done = safari.buttons["Done"]
            if done.exists { done.tap() }
        }
        for attempt in 1...2 {
            field.tap(); assertFullRows(in: safari, context: "Search reactivation \(attempt)")
            multiline.tap(); assertFullRows(in: safari, context: "Multiline reactivation \(attempt)")
        }
        clear.activate(); safari.activate()
        multiline.tap(); assertFullRows(in: safari, context: "Safari after changing host app")
    }
}
