import XCTest
import UIKit

@MainActor final class AppUITests: XCTestCase {
    private let clear = XCUIApplication(bundleIdentifier: "com.example.clearkeyboard")
    private func attachment(_ app: XCUIApplication, name: String) {
        let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<7 { if element.exists && element.isHittable { return }; app.swipeUp() }
    }
    func testEveryTabCanScrollItsLastControlAboveTheBottomBar() throws {
        continueAfterFailure = false; clear.terminate(); clear.launch()
        let bar = clear.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 8))
        for (tab, identifier) in [("澈", "home.footer"), ("定制", "custom.toolbarEditor"), ("输入", "input.resetLearning")] {
            XCTContext.runActivity(named: "Open tab " + tab) { _ in bar.buttons[tab].tap() }
            let last = clear.descendants(matching: .any).matching(identifier: identifier).firstMatch
            let scroll = clear.scrollViews.firstMatch
            for _ in 0..<10 {
                if last.exists && last.isHittable && last.frame.maxY < bar.frame.minY { break }
                XCTContext.runActivity(named: "Reveal last control " + identifier) { _ in scroll.swipeUp() }
            }
            XCTAssertTrue(last.exists && last.isHittable, "Last control must be reachable in " + tab)
            XCTAssertLessThan(last.frame.maxY, bar.frame.minY, "The tab bar covers content in " + tab)
            XCTAssertFalse(clear.buttons["home.practice"].exists, "The removed practice screen must have no entry")
            print("APP_BOTTOM_REACHABLE tab=\(tab) lastMaxY=\(last.frame.maxY) barMinY=\(bar.frame.minY)")
            attachment(clear, name: "redesigned-" + identifier)
        }
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.windows.count == 0 && springboard.icons.count == 0 {
            let status = "DESKTOP_ICON_VERIFICATION status=unavailable reason=system-shell-exposes-no-launcher-windows-or-icons"
            print(status)
            let detail = XCTAttachment(string: status + "\n" + springboard.debugDescription)
            detail.name = "Desktop58-launcher-unavailable"; detail.lifetime = .keepAlways; add(detail)
        } else {
            let icon = springboard.icons.matching(identifier: "澈").firstMatch
            for _ in 0..<4 {
                if icon.exists && icon.isHittable { break }
                springboard.swipeLeft()
            }
            XCTAssertTrue(icon.exists && icon.isHittable,"The built app icon must be visible when the launcher exposes icons")
            if icon.exists && icon.isHittable {
                let shot = icon.screenshot()
                let value = XCTAttachment(screenshot: shot); value.name = "Desktop58-icon-native"; value.lifetime = .keepAlways; add(value)
                // Check the empty top-center background, inside the system icon
                // silhouette and above the foreground. Source alpha alone did
                // not catch the system adding a white backplate in Light mode.
                let bitmap = try XCTUnwrap(shot.image.cgImage)
                let side = CGFloat(bitmap.width)
                let strip = try XCTUnwrap(bitmap.cropping(to: CGRect(x: side*0.4,y: side*0.06,width: side*0.2,height: side*0.03).integral))
                var rgba = [UInt8](repeating: 0,count: strip.width*strip.height*4)
                try rgba.withUnsafeMutableBytes { raw in
                    let context = try XCTUnwrap(CGContext(data: raw.baseAddress,width: strip.width,height: strip.height,bitsPerComponent: 8,bytesPerRow: strip.width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.draw(strip,in: CGRect(x: 0,y: 0,width: CGFloat(strip.width),height: CGFloat(strip.height)))
                }
                let brightness = stride(from: 0,to: rgba.count,by: 4).map { (Double(rgba[$0])+Double(rgba[$0+1])+Double(rgba[$0+2]))/3 }.reduce(0,+)/Double(strip.width*strip.height)
                XCTAssertLessThan(brightness,140,"The actual desktop icon must not acquire a white backplate")
                print("DESKTOP_ICON_BACKPLATE meanRGB=\(brightness) whiteBackplate=false")
                attachment(springboard,name: "Desktop58-home-native")
                print("DESKTOP_ICON_VERIFICATION status=reviewable")
            }
        }
        clear.activate()
    }


    private func openAppearance(_ name: String) -> XCUIElement {
        continueAfterFailure = false; clear.launch()
        clear.tabBars.buttons["定制"].tap()
        let entry = clear.descendants(matching: .any).matching(identifier: "custom.edit." + name).firstMatch
        reveal(entry, in: clear); XCTAssertTrue(entry.isHittable, name); entry.tap()
        let preview = clear.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["preview." + name, "appearance.preview"] as NSArray)).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 4), "Missing live preview for " + name)
        return preview
    }
    private func exerciseAppearance(_ name: String) {
        let preview = openAppearance(name)
        let before = preview.value as? String
        XCTAssertNotNil(before, "The preview must expose the settings it actually rendered")
        let oldPixels = preview.screenshot().pngRepresentation
        if name == "keyGlass" { attachment(clear,name: "Glass58-key-glass-native-before") }
        if name == "keyGlass" {
            let slider = clear.sliders["appearance.strength." + name]
            XCTAssertTrue(slider.exists)
            slider.adjust(toNormalizedSliderPosition: (before ?? "").contains("0.9;") ? 0.15 : 0.9)
        } else if name == "candidateSize" {
            let picker = clear.segmentedControls["custom.candidateTextSize"]
            picker.buttons[picker.buttons["特大"].isSelected ? "小" : "特大"].tap()
        } else {
            let target = (before ?? "").contains("#E3AC72") ? "#558DF2" : "#E3AC72"
            let swatch = clear.buttons[target]; reveal(swatch, in: clear); XCTAssertTrue(swatch.isHittable); swatch.tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in (preview.value as? String) != before }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 4), .completed, "The live preview did not consume the new setting")
        XCTAssertNotEqual(preview.screenshot().pngRepresentation, oldPixels, "The preview's visible pixels must change with its control")
        if name == "keyGlass" { attachment(clear,name: "Glass58-key-glass-native-after") }
        XCTAssertTrue(preview.exists); XCTAssertEqual(clear.state, .runningForeground)
        print("APPEARANCE_PAGE name=" + name + " livePreview=true controlChanged=true")
    }
    func testAppearanceKeyGlass() { exerciseAppearance("keyGlass") }
    func testAppearanceKeyColor() { exerciseAppearance("keyColor") }
    func testAppearanceCandidateColor() { exerciseAppearance("candidateColor") }
    func testAppearanceCandidateSize() { exerciseAppearance("candidateSize") }
    private func exerciseColorSwatchAndHEX(_ name: String) {
        func expectValue(_ element: XCUIElement, _ text: String, contains: Bool = false) {
            let predicate = NSPredicate(format: contains ? "value CONTAINS %@" : "value == %@", text)
            let changed = XCTNSPredicateExpectation(predicate: predicate, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 4), .completed, "The current color and its HEX display diverged: " + text)
        }
        func recordState(_ page: String, _ stage: String, preview: XCUIElement, field: XCUIElement, apply: XCUIElement) {
            XCTContext.runActivity(named: "Color HEX " + page + " / " + stage) { activity in
                let state = "page=\(page) stage=\(stage) preview=\(String(describing: preview.value)) HEX=\(String(describing: field.value)) applyEnabled=\(apply.isEnabled) applyHittable=\(apply.isHittable) keyboardVisible=\(clear.keyboards.firstMatch.exists)"
                let details = XCTAttachment(string: state); details.name = "color-state-" + page + "-" + stage; details.lifetime = .keepAlways; activity.add(details)
                let pixels = XCTAttachment(screenshot: clear.screenshot()); pixels.name = "color-" + page + "-" + stage; pixels.lifetime = .keepAlways; activity.add(pixels)
                print("COLOR_HEX_STATE " + state)
            }
        }
        func replaceHEX(_ text: String, in field: XCUIElement) {
            reveal(field, in: clear)
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let current = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
        }
        let preview = openAppearance(name)
        let blue = clear.buttons["#558DF2"]
        reveal(blue, in: clear); XCTAssertTrue(blue.isHittable); blue.tap()
        expectValue(preview, name + ":#558DF2", contains: true)
        let field = clear.textFields["appearance.hex"]
        XCTAssertTrue(field.exists); expectValue(field, "#558DF2")
        let apply = clear.buttons["appearance.applyHex"]
        XCTAssertFalse(apply.isEnabled, "Selecting a swatch must leave no stale HEX draft available to apply")
        XCTAssertTrue(blue.isSelected)
        let selected = preview.value as? String
        blue.tap()
        XCTAssertEqual(preview.value as? String, selected, "Selecting the active swatch must be idempotent")
        XCTAssertFalse(apply.isEnabled)
        attachment(clear, name: "color-current-hex-" + name)

        replaceHEX("#1A2B3C", in: field)
        XCTAssertTrue(apply.isEnabled, "Only an explicitly edited HEX value should enable Apply")
        recordState(name, "manual-draft", preview: preview, field: field, apply: apply)
        reveal(apply, in: clear); XCTAssertTrue(apply.isHittable); apply.tap()
        expectValue(preview, name + ":#1A2B3C", contains: true)
        expectValue(field, "#1A2B3C")
        recordState(name, "manual-applied", preview: preview, field: field, apply: apply)
        XCTAssertFalse(apply.isEnabled, name + ": an applied HEX value must not remain an actionable draft")

        // Re-entering the current color is not another change to save.
        // Return must also normalize and finish a genuinely new HEX draft.
        replaceHEX("#1A2B3C", in: field)
        expectValue(field, "#1A2B3C")
        XCTAssertFalse(apply.isEnabled, name + ": an equivalent HEX edit must not re-enable Apply")
        field.typeText("\n")
        expectValue(preview, name + ":#1A2B3C", contains: true)
        replaceHEX("#123\n", in: field)
        expectValue(preview, name + ":#112233", contains: true)
        expectValue(field, "#112233")
        recordState(name, "return-applied", preview: preview, field: field, apply: apply)
        XCTAssertFalse(apply.isEnabled, name + ": Return must finish the HEX draft just like Apply")

        let reset = clear.buttons["appearance.reset." + name]
        reveal(reset, in: clear); XCTAssertTrue(reset.isHittable); reset.tap()
        expectValue(preview, name + ":auto", contains: true)
        XCTAssertTrue(reset.isSelected)
        let defaults = preview.value as? String, defaultHex = field.value as? String
        reset.tap()
        XCTAssertEqual(preview.value as? String, defaults)
        XCTAssertEqual(field.value as? String, defaultHex)
        XCTAssertFalse(apply.isEnabled)
        attachment(clear, name: "color-manual-and-default-" + name)
        print("COLOR_HEX_UI name=\(name) swatchMatchesCurrentHex=true noStaleApply=true manualHexApplies=true equivalentEditDisabled=true returnNormalizes=true defaultIdempotent=true")
    }
    func testKeyColorSwatchAndHEXStayConsistent() { exerciseColorSwatchAndHEX("keyColor") }
    func testCandidateColorSwatchAndHEXStayConsistent() { exerciseColorSwatchAndHEX("candidateColor") }
    func testAppearancePersistenceAndToolbar() {
        _ = openAppearance("candidateSize")
        let size = clear.segmentedControls["custom.candidateTextSize"]
        let selected = size.buttons["特大"].isSelected ? "小" : "特大"
        size.buttons[selected].tap()
        clear.navigationBars.buttons.element(boundBy: 0).tap()
        let toolbar = clear.buttons["custom.toolbarEditor"]; reveal(toolbar, in: clear); toolbar.tap()
        XCTAssertTrue(clear.navigationBars["快捷工具"].waitForExistence(timeout: 4))
        clear.buttons["完成"].tap()
        clear.terminate(); clear.launch(); clear.tabBars.buttons["定制"].tap()
        let entry = clear.descendants(matching: .any).matching(identifier: "custom.edit.candidateSize").firstMatch
        reveal(entry, in: clear); entry.tap()
        XCTAssertTrue(clear.segmentedControls["custom.candidateTextSize"].buttons[selected].isSelected)
        print("APPEARANCE_PERSISTENCE persistedAfterRelaunch=true toolbarEditor=true")
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
        if q.waitForExistence(timeout: 2) { return }
        let globe = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Next keyboard' OR label CONTAINS[c] 'Switch keyboard' OR label CONTAINS '下一个键盘'")).firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 3), app.debugDescription)
        globe.press(forDuration: 1)
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "澈")).firstMatch
        if named.waitForExistence(timeout: 3) {
            named.tap()
            if q.waitForExistence(timeout: 8) { return }
        } else if globe.exists { globe.tap() }
        for _ in 0..<8 {
            if q.waitForExistence(timeout: 2) { return }
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
        let root = app.descendants(matching: .any).matching(identifier: "clear.keyboard.root").firstMatch
        XCTAssertTrue(root.exists, context + " keyboard root is missing")
        XCTAssertEqual(root.frame.height, 276, accuracy: 0.5, context + " expanded the remote keyboard root")
        // Measure screen-space hit rectangles, including any host view transform.
        XCTAssertEqual(q.frame.height, 56, accuracy: 0.5, context + ": " + String(describing: q.frame))
        XCTAssertEqual(a.frame.minY - q.frame.minY, 56, accuracy: 0.5, context)
        XCTAssertEqual(z.frame.minY - a.frame.minY, 56, accuracy: 0.5, context)
        XCTAssertEqual(language.frame.minY - z.frame.minY, 56, accuracy: 0.5, context)
        XCTAssertGreaterThan(q.frame.minY, app.frame.height * 0.5, context + " placed keys over the webpage")
        XCTAssertLessThan(language.frame.maxY, app.frame.height - 34, context + " covered the system keyboard controls")
        XCTAssertTrue(q.isHittable && language.isHittable, context + " clipped a keyboard row")
        print("SAFARI_ROWS " + context + " q=" + String(describing: q.frame) + " language=" + String(describing: language.frame))
    }
    private func focusInput(_ field: XCUIElement, in app: XCUIApplication, expectedFocus: String? = nil) {
        let q = app.descendants(matching: .any).matching(identifier: "key.text.q").firstMatch
        let globe = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Next keyboard' OR label CONTAINS[c] 'Switch keyboard' OR label CONTAINS '下一个键盘'")).firstMatch
        for attempt in 0..<3 {
            if attempt == 0 { field.tap() }
            else {
                print("SAFARI_FOCUS_RETRY \(attempt)")
                // WebKit can finish a marked-text session before focusing a different DOM input.
                // Use a fresh interior coordinate when that first tap only dismissed the keyboard.
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).tap()
            }
            if let expectedFocus {
                // A visible keyboard can still belong to the previous DOM field. Check
                // the fixture's actual focus event before measuring or sending a key.
                let focused = app.webViews.staticTexts["Editing: " + expectedFocus].firstMatch
                if !focused.waitForExistence(timeout: 2) { continue }
            }
            if q.waitForExistence(timeout: 2) || globe.waitForExistence(timeout: 2) {
                chooseKeyboard(in: app); return
            }
        }
        XCTFail("Safari did not focus the requested input\n" + app.debugDescription)
    }
    func testBSafariSearchAndMultilineKeepFullKeyboardRows() throws {
        continueAfterFailure = false; clear.launch(); try enableKeyboard()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari"); safari.launch()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
        for title in ["Continue", "Continue", "Start Browsing", "Not Now"] {
            if safari.buttons[title].waitForExistence(timeout: 2) { safari.buttons[title].tap() }
        }
        let search = safari.webViews.searchFields.matching(identifier: "Safari search size check").firstMatch
        let fallbackSearch = safari.webViews.textFields.matching(identifier: "Safari search size check").firstMatch
        let field = search.waitForExistence(timeout: 5) ? search : fallbackSearch
        XCTAssertTrue(field.waitForExistence(timeout: 8), safari.debugDescription)
        focusInput(field, in: safari, expectedFocus: "Safari search size check")
        let q = safari.descendants(matching: .any).matching(identifier: "key.text.q").firstMatch
        let z = safari.descendants(matching: .any).matching(identifier: "key.text.z").firstMatch
        let language = safari.descendants(matching: .any).matching(identifier: "key.language").firstMatch
        XCTAssertEqual(q.frame.height, 56, accuracy: 0.5, "Safari compressed the letter row: " + String(describing: q.frame))
        let a = safari.descendants(matching: .any).matching(identifier: "key.text.a").firstMatch
        XCTAssertEqual(a.frame.minY - q.frame.minY, 56, accuracy: 0.5)
        XCTAssertGreaterThan(z.frame.minY, q.frame.maxY)
        XCTAssertGreaterThanOrEqual(language.frame.minY, z.frame.maxY)
        assertFullRows(in: safari, context: "Safari search input")
        let searchHeight = q.frame.height
        q.tap(); XCTAssertTrue((field.value as? String)?.lowercased().contains("q") == true)
        // Commit this field's marked spelling and select English before testing a
        // literal ASCII key. Committing Chinese 'w' may correctly produce a Han word.
        if language.label.hasPrefix("中文") { language.tap() }
        XCTAssertTrue(language.label.hasPrefix("英文"))
        attachment(safari, name: "safari-search-keyboard")
        let multiline = safari.webViews.textViews.matching(identifier: "Safari multiline size check").firstMatch
        XCTAssertTrue(multiline.exists); focusInput(multiline, in: safari, expectedFocus: "Safari multiline size check")
        XCTAssertEqual(q.frame.height, searchHeight, accuracy: 1)
        XCTAssertEqual(q.frame.height, 56, accuracy: 0.5)
        XCTAssertEqual(a.frame.minY - q.frame.minY, 56, accuracy: 0.5)
        assertFullRows(in: safari, context: "Safari multiline input")
        let w = safari.descendants(matching: .any).matching(identifier: "key.text.w").firstMatch
        w.tap()
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS[c] %@", "w"), object: multiline)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "Typing must reach the newly focused textarea\n" + safari.debugDescription)
        attachment(safari, name: "safari-multiline-keyboard")
        // Safari compresses its address capsule while editing a web form. Dismiss that
        // input with the observed accessory control, then select the actual address field.
        let formDone = safari.buttons["Done"]
        XCTAssertTrue(formDone.exists, safari.debugDescription); formDone.tap()
        // The address bar uses different input traits from a webpage search field.
        let address = safari.textFields.matching(NSPredicate(format: "identifier == 'TabBarItemTitle' OR identifier == 'URL' OR label CONTAINS[c] 'Address'")).firstMatch
        if address.exists && address.isHittable { focusInput(address, in: safari) }
        else {
            let location = safari.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'URL' OR label == 'Address' OR label == 'Search or enter website name' OR (elementType == 9 AND label CONTAINS '127.0.0.1')")).firstMatch
            XCTAssertTrue(location.waitForExistence(timeout: 5), "Address bar missing\n" + safari.debugDescription)
            focusInput(location, in: safari)
        }
        assertFullRows(in: safari, context: "Safari address bar")
        let cancel = safari.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
        else {
            let done = safari.buttons["Done"]
            if done.exists { done.tap() }
        }
        for attempt in 1...2 {
            focusInput(field, in: safari, expectedFocus: "Safari search size check"); assertFullRows(in: safari, context: "Search reactivation \(attempt)")
            focusInput(multiline, in: safari, expectedFocus: "Safari multiline size check"); assertFullRows(in: safari, context: "Multiline reactivation \(attempt)")
        }
        clear.activate(); safari.activate()
        focusInput(multiline, in: safari, expectedFocus: "Safari multiline size check"); assertFullRows(in: safari, context: "Safari after changing host app")
    }
}

