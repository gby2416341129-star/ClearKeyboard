import XCTest
import UIKit

/// Diagnostic of the installed .appex through the system keyboard picker.
/// No local KeyboardViewController, inputView override or simulated shell is used.
@MainActor final class KeyboardShellUITests: XCTestCase {
    private enum Source: String { case english, emoji }
    private let appID = ProcessInfo.processInfo.environment["CLEAR_SHELL_APP_BUNDLE_ID"] ?? "com.example.clearkeyboard"
    private var samples: [[String: Any]] = []
    private var discrepancies: [String] = []
    private var hostLimitations: [String] = []
    private var settingsListVerified = false
    private var settingsNativeListVerifiedBeforeAdd = false
    private var settingsAddPerformed = false
    private var started = Date()
    private struct EvidenceUnavailable: Error, CustomStringConvertible {
        let description: String
    }
    private var clear: XCUIApplication { XCUIApplication(bundleIdentifier: appID) }
    private func elements(_ app: XCUIApplication, identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }
    private func key(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        // App appearance previews deliberately reuse key identifiers. Only
        // descendants of the actual extension root may prove a connected key.
        root(in: app).descendants(matching: .any).matching(identifier: "key.text." + name).firstMatch
    }
    private func root(in app: XCUIApplication) -> XCUIElement {
        elements(app, identifier: "clear.keyboard.root").firstMatch
    }
    private func control(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        root(in: app).descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    private func unavailable(_ message: String, in app: XCUIApplication) -> EvidenceUnavailable {
        screen("unavailable-evidence")
        attachTree(app, "unavailable-evidence")
        return EvidenceUnavailable(description: message)
    }
    private func bounded() {
        XCTAssertLessThan(Date().timeIntervalSince(started), 280, "Connected extension diagnostic exceeded its Settings-and-host interaction budget")
    }
    private func screen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "connected-shell-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func attachTree(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "connected-shell-AX-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func jsonRect(_ frame: CGRect) -> [String: Double] {
        ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }
    private func settingsText(_ label: String, in app: XCUIApplication) -> XCUIElement {
        // Navigation titles can have the same text as the next settings row.
        app.cells.staticTexts.matching(identifier: label).firstMatch
    }
    private func tapSettingsText(_ label: String, in app: XCUIApplication) throws {
        // Settings rows can expose their title as StaticText, Button or
        // Cell. All alternatives remain scoped to cells, never a nav title.
        let exact = NSPredicate(format: "label == %@ OR identifier == %@", label, label)
        let candidates = [settingsText(label, in: app),
                          app.cells.matching(exact).firstMatch,
                          app.cells.buttons.matching(exact).firstMatch]
        // A virtualized row may not exist until scrolling creates it. Keep
        // the original bounded reveal behavior across all scoped variants.
        for attempt in 0...5 {
            if let target = candidates.first(where: { $0.exists && $0.isHittable }) {
                target.tap(); return
            }
            if attempt < 5 { app.swipeUp() }
        }
        throw unavailable("Settings row is not hittable: " + label, in: app)
    }
    private func enableKeyboardInSystemSettings() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate(); settings.launch(); settings.activate()
        guard settings.wait(for: .runningForeground, timeout: 8) else {
            throw unavailable("System Settings did not enter the foreground", in: settings)
        }
        // Observed iOS 26.4 AX: the enabled-list Add control is Cell
        // AddNewKeyboard containing a Button, not a StaticText descendant.
        func addRow() -> XCUIElement { settings.cells.matching(identifier: "AddNewKeyboard").firstMatch }
        let keyboardsRow = settings.cells.matching(identifier: "KEYBOARDS").firstMatch
        // Settings can restore a previous navigation stack. Walk back only
        // through its visible navigation control to a positively known page.
        for _ in 0..<4 {
            if addRow().exists || keyboardsRow.exists || settingsText("General", in: settings).exists { break }
            let back = settings.navigationBars.buttons.firstMatch
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
        if !addRow().exists && !keyboardsRow.exists {
            try tapSettingsText("General", in: settings)
            try tapSettingsText("Keyboard", in: settings)
        }
        if !addRow().exists {
            guard keyboardsRow.waitForExistence(timeout: 5), keyboardsRow.isHittable else {
                throw unavailable("The actual Settings Keyboards list is unavailable", in: settings)
            }
            keyboardsRow.tap()
        }
        guard addRow().waitForExistence(timeout: 6) else {
            throw unavailable("Settings exposed no enabled-keyboard list; preference readback is not UI activation proof", in: settings)
        }
        // Initial native configuration is verified here in the actual UI,
        // never inferred from an absent defaults key or prepared by mutation.
        func listed(_ predicate: NSPredicate) -> Bool {
            settings.cells.matching(predicate).firstMatch.exists ||
            settings.cells.staticTexts.matching(predicate).firstMatch.exists ||
            settings.cells.buttons.matching(predicate).firstMatch.exists
        }
        let english = NSPredicate(format: "label BEGINSWITH[c] 'English'")
        let emoji = NSPredicate(format: "label == 'Emoji'")
        let clear = NSPredicate(format: "label == '澈' OR label BEGINSWITH '澈 —' OR label BEGINSWITH '澈 -'")
        guard listed(english), listed(emoji), !listed(clear) else {
            throw unavailable("Before Add, the actual enabled-keyboard list must contain English and Emoji with no 澈", in: settings)
        }
        settingsNativeListVerifiedBeforeAdd = true
        screen("system-settings-native-keyboards-before-add")
        attachTree(settings, "system-settings-native-keyboards-before-add")
        print("KEYBOARD_SETTINGS_BEFORE_ADD english=true emoji=true clear=false preferenceReadbackAloneAccepted=false")
        addRow().tap()
        try tapSettingsText("澈", in: settings)
        settingsAddPerformed = true
        // Some Settings versions show a per-keyboard switch before the
        // enabled list. Turn on that actual switch when it is presented.
        let enabled = settings.switches.matching(NSPredicate(format: "label == '澈' OR label BEGINSWITH '澈,'")).firstMatch
        if enabled.exists, (enabled.value as? String) == "0" { enabled.tap() }
        if !addRow().exists {
            let back = settings.navigationBars.buttons.firstMatch
            guard back.exists, back.isHittable else {
                throw unavailable("Could not return from Add Keyboard to the enabled list", in: settings)
            }
            back.tap()
        }
        guard addRow().waitForExistence(timeout: 5) else {
            throw unavailable("Could not confirm the enabled-keyboard list after Add", in: settings)
        }
        let added = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            listed(clear) && listed(english) && listed(emoji)
        }, object: nil)
        guard XCTWaiter.wait(for: [added], timeout: 5) == .completed else {
            throw unavailable("The actual Settings list did not confirm English, Emoji and 澈 after Add", in: settings)
        }
        settingsListVerified = true
        screen("system-settings-enabled-keyboards")
        attachTree(settings, "system-settings-enabled-keyboards")
        print("KEYBOARD_SETTINGS_LIST_CONFIRMED english=true emoji=true clear=true preferenceReadbackAloneAccepted=false")
        XCUIDevice.shared.press(.home)
    }
    private func globe(in app: XCUIApplication) -> XCUIElement? {
        let query = app.buttons.matching(NSPredicate(format:
            "label CONTAINS[c] 'Next keyboard' OR label CONTAINS[c] 'Switch keyboard' OR label CONTAINS '下一个键盘'"))
        guard query.firstMatch.waitForExistence(timeout: 3) else { return nil }
        let keyboard = app.keyboards.firstMatch
        let visible = query.allElementsBoundByIndex.filter {
            $0.isHittable && (!keyboard.exists || $0.frame.midY >= keyboard.frame.minY)
        }
        return visible.max(by: { $0.frame.midY < $1.frame.midY })
    }
    @discardableResult private func choose(_ label: String, in app: XCUIApplication, required: Bool = true) throws -> Bool {
        bounded()
        // The system can restore our already-selected keyboard when the field
        // gains focus. Confirm its actual keys before opening a second picker.
        // All subsequent typed-text and production-state assertions still run.
        if label == "澈", key(app, "q").waitForExistence(timeout: 5), key(app, "q").isHittable { return true }
        if label == "澈" {
            // Cycle the real system globe, avoiding ambiguous menu containers.
            // A visible, hittable extension key is the only success condition.
            for index in 0..<4 {
                guard let next = self.globe(in: app) else { break }
                next.tap()
                if key(app, "q").waitForExistence(timeout: 5), key(app, "q").isHittable { return true }
                screen("custom-cycle-\(index)"); attachTree(app, "custom-cycle-\(index)")
            }
            throw unavailable("System keyboard cycling did not expose the actual extension", in: app)
        }
        guard let globe = self.globe(in: app) else {
            if required { throw unavailable("System keyboard picker is unavailable after Settings-list confirmation", in: app) }
            hostLimitations.append("App ASCII HEX field: system keyboard picker unavailable; no extension connection claimed")
            screen("app-hex-picker-unavailable"); attachTree(app, "app-hex-picker-unavailable")
            return false
        }
        globe.press(forDuration: 0.8)
        let predicate = label == "English"
            ? NSPredicate(format: "label BEGINSWITH[c] %@", label)
            : NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + " ")
        let query = app.descendants(matching: .any).matching(predicate)
        guard query.firstMatch.waitForExistence(timeout: 4) else {
            if required { throw unavailable("System keyboard menu target missing: " + label, in: app) }
            hostLimitations.append("App ASCII HEX field: system menu excludes " + label + "; this transition was not verified")
            screen("app-hex-source-unavailable"); attachTree(app, "app-hex-source-unavailable")
            return false
        }
        // The containing App also has a tab called 澈. Require a visible menu
        // item near the keyboard rather than accidentally tapping that tab.
        let visible = query.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.midY > app.frame.height * 0.4 }
        let target = visible.max(by: { $0.frame.midY < $1.frame.midY })
        guard let target else {
            if required { throw unavailable("No hittable system keyboard menu item for " + label, in: app) }
            hostLimitations.append("App ASCII HEX field: no hittable " + label + " menu item; this transition was not verified")
            screen("app-hex-source-unavailable"); attachTree(app, "app-hex-source-unavailable")
            return false
        }
        target.tap()
        return true
    }
    @discardableResult private func selectNative(_ source: Source, in app: XCUIApplication, host: String, required: Bool = true) throws -> Bool {
        guard try choose(source == .english ? "English" : "Emoji", in: app, required: required) else { return false }
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let customQ = self.key(app, "q")
            return !customQ.exists || !customQ.isHittable
        }, object: nil)
        guard XCTWaiter.wait(for: [hidden], timeout: 5) == .completed else {
            throw unavailable("The actual extension root did not yield to " + source.rawValue, in: app)
        }
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 4) else {
            throw unavailable("Native keyboard accessibility frame is missing", in: app)
        }
        if source == .english {
            let nativeQ = keyboard.keys.matching(NSPredicate(format: "label == 'q' OR label == 'Q'")).firstMatch
            guard nativeQ.waitForExistence(timeout: 4) else {
                throw unavailable("English was not confirmed by an actual native Q key", in: app)
            }
        } else {
            let emojiProof = keyboard.descendants(matching: .any).matching(NSPredicate(format:
                "label == 'ABC' OR label CONTAINS[c] 'Search Emoji' OR label CONTAINS[c] 'Frequently Used' OR label CONTAINS[c] 'Recents'"))
            guard emojiProof.firstMatch.waitForExistence(timeout: 4) else {
                throw unavailable("Emoji keyboard could not be positively identified", in: app)
            }
        }
        screen(host + "-native-" + source.rawValue)
        return true
    }
    private func ensureCustomEnglish(_ app: XCUIApplication) throws {
        let language = control(app, "key.language")
        guard language.waitForExistence(timeout: 5) else {
            throw unavailable("The actual extension language control is missing", in: app)
        }
        // Both labels mention the other language in their action hint. Only
        // the leading mode identifies the mode that will receive a literal Q.
        if language.label.hasPrefix("中文") { language.tap() }
        let english = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            language.label.hasPrefix("英文") || language.label.lowercased().hasPrefix("english")
        }, object: nil)
        guard XCTWaiter.wait(for: [english], timeout: 3) == .completed else {
            throw unavailable("Literal connection proof needs the extension's English mode", in: app)
        }
    }
    private func captureCustom(_ app: XCUIApplication, field: XCUIElement, name: String) throws -> (CGRect, CGRect) {
        bounded()
        guard key(app, "q").waitForExistence(timeout: 8) else {
            throw unavailable("Installed extension keys did not appear inside clear.keyboard.root", in: app)
        }
        try ensureCustomEnglish(app)
        let root = self.root(in: app)
        let runtime = control(app, "clear.keyboard.runtime")
        guard root.waitForExistence(timeout: 4), runtime.waitForExistence(timeout: 4) else {
            throw unavailable("Actual extension root/.appex metadata unavailable; an App preview is not proof", in: app)
        }
        let payload = try XCTUnwrap(runtime.value as? String, "The DEBUG extension runtime element must expose JSON")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(metadata["bundleExtension"] as? String, "appex")
        let identifier = try XCTUnwrap(metadata["bundleIdentifier"] as? String)
        XCTAssertTrue(identifier.hasPrefix(appID + "."), "This is not the containing App's installed extension")
        XCTAssertGreaterThan((metadata["pid"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertEqual(metadata["hostActive"] as? Bool, true)
#if SHELL_AB_DEFAULT_ROOT || SHELL_AB_KEYBOARD_ROOT
#if SHELL_AB_DEFAULT_ROOT
        let expectedRecipe = "default-root", expectedStyle = UIInputView.Style.default.rawValue
#else
        let expectedRecipe = "keyboard-root", expectedStyle = UIInputView.Style.keyboard.rawValue
#endif
        XCTAssertEqual(metadata["shellABRecipe"] as? String, expectedRecipe)
        XCTAssertEqual((metadata["shellABActualInputViewStyle"] as? NSNumber)?.intValue, expectedStyle)
        let rgba = try XCTUnwrap(metadata["shellABActualRootRGBA"] as? [Double])
        XCTAssertEqual(rgba.count, 4)
        if rgba.count == 4 {
            for (actual, expected) in zip(rgba, [85.0 / 255.0, 141.0 / 255.0, 242.0 / 255.0, 1.0]) {
                XCTAssertEqual(actual, expected, accuracy: 0.002, "The runtime must prove the A/B root tint, not merely its compile flag")
            }
        }
#endif
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 4), "Host keyboard AX frame missing; external shell cannot be measured")
        let q = key(app, "q"), a = key(app, "a"), z = key(app, "z")
        for element in [root, keyboard, q, a, z] {
            XCTAssertTrue(element.frame.width.isFinite && element.frame.height.isFinite && element.frame.width > 0 && element.frame.height > 0)
        }
        screen(name)
        attachTree(app, name)
        let rootFrame = root.frame, keyboardFrame = keyboard.frame
        let screenImage = XCUIScreen.main.screenshot().image
        let pixelWidth = screenImage.cgImage?.width ?? Int(screenImage.size.width * screenImage.scale)
        let pixelHeight = screenImage.cgImage?.height ?? Int(screenImage.size.height * screenImage.scale)
        var sample: [String: Any] = ["name": name, "runtime": metadata,
            "screenSizePoints": [Double(UIScreen.main.bounds.width), Double(UIScreen.main.bounds.height)],
            "screenPixels": [pixelWidth, pixelHeight],
            "screenshotPixelsPerPoint": Double(pixelWidth) / Double(UIScreen.main.bounds.width),
            "rootFrame": jsonRect(rootFrame), "keyboardFrameAX": jsonRect(keyboardFrame),
            "qFrame": jsonRect(q.frame), "aFrame": jsonRect(a.frame), "zFrame": jsonRect(z.frame),
            "rootTopMinusKeyboardTop": Double(rootFrame.minY - keyboardFrame.minY),
            "keyboardBottomMinusRootBottom": Double(keyboardFrame.maxY - rootFrame.maxY),
            "outerFrameSource": "public-XCUIElement-keyboard-AX-not-private-host-constraints",
            "nativeChromeGeometryFixed": false]
        // The metadata establishes .appex identity; this is the separate proof
        // that its real textDocumentProxy is connected to this focused host.
        let old = field.value as? String ?? ""
        let oldQ = old.lowercased().filter { $0 == "q" }.count
        q.tap()
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = field.value as? String ?? ""
            return current != old && current.lowercased().filter { $0 == "q" }.count > oldQ
        }, object: nil)
        let result = XCTWaiter.wait(for: [inserted], timeout: 5)
        sample["qReachedFocusedHost"] = result == .completed
        samples.append(sample)
        XCTAssertEqual(result, .completed, "A real custom-keyboard Q tap did not reach the focused host")
        print("CONNECTED_KEYBOARD_SHELL " + name + " root=" + String(describing: rootFrame) + " keyboardAX=" + String(describing: keyboardFrame) + " metadata=" + payload)
        return (rootFrame, keyboardFrame)
    }
    private func compare(_ previous: (CGRect, CGRect), _ current: (CGRect, CGRect), name: String) {
        let metrics: [(String, CGFloat, CGFloat)] = [
            ("rootHeight", previous.0.height, current.0.height),
            ("rootWidth", previous.0.width, current.0.width),
            ("hostKeyboardHeightAX", previous.1.height, current.1.height),
            ("topGapAX", previous.0.minY - previous.1.minY, current.0.minY - current.1.minY),
            ("bottomGapAX", previous.1.maxY - previous.0.maxY, current.1.maxY - current.0.maxY)
        ]
        for (metric, first, second) in metrics where abs(first - second) > 1 {
            discrepancies.append("\(name): \(metric) changed \(first) -> \(second) points")
        }
    }
    private func sequence(in app: XCUIApplication, field: XCUIElement, host: String, permitsASCIIRestriction: Bool = false) throws {
        guard try selectNative(.english, in: app, host: host, required: !permitsASCIIRestriction) else { return }
        guard try choose("澈", in: app, required: !permitsASCIIRestriction) else { return }
        let english = try captureCustom(app, field: field, name: host + "-english-to-custom")
        guard try selectNative(.emoji, in: app, host: host, required: !permitsASCIIRestriction) else { return }
        guard try choose("澈", in: app, required: !permitsASCIIRestriction) else { return }
        let emoji = try captureCustom(app, field: field, name: host + "-emoji-to-custom")
        compare(english, emoji, name: host + " English versus Emoji entry")
        // Keep the editor focused. Tapping it again would hide the app-return
        // condition described in the 17pt system-shell regression report.
        XCUIDevice.shared.press(.home)
        app.activate()
        let returned = try captureCustom(app, field: field, name: host + "-focused-home-return")
        compare(emoji, returned, name: host + " focused Home/return")
    }
    func testConnectedExtensionShellAcrossEnglishEmojiAndHostReturn() throws {
        continueAfterFailure = false; started = Date()
        let app = clear
        defer {
            screen("final-state")
            if app.state == .runningForeground { attachTree(app, "final-app") }
            else {
                let foregroundSafari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
                if foregroundSafari.state == .runningForeground { attachTree(foregroundSafari, "final-safari") }
            }
            let connected = samples.contains { $0["qReachedFocusedHost"] as? Bool == true }
            let safariCompleted = samples.filter {
                ($0["name"] as? String)?.hasPrefix("safari-") == true && $0["qReachedFocusedHost"] as? Bool == true
            }.count == 3
            let report: [String: Any] = ["schema": 2, "samples": samples, "geometryDiscrepancies": discrepancies,
                "runtimeOS": UIDevice.current.systemVersion, "elapsedSeconds": Date().timeIntervalSince(started),
                "verification": connected ? "installed-extension-system-picker-and-real-host-input" : "not-verified",
                "systemSettingsKeyboardListVerified": settingsListVerified,
                "systemSettingsNativeOnlyListVerifiedBeforeAdd": settingsNativeListVerifiedBeforeAdd,
                "systemSettingsAddKeyboardPerformed": settingsAddPerformed,
                "fullAccessChangedByDiagnostic": false,
                "actualExtensionConnected": connected, "hostLimitations": hostLimitations,
                "mandatorySafariTransitionsVerified": safariCompleted,
                "nativeChromeGeometryFixed": false, "simulatedChromeUsed": false,
                "limits": "AX keyboard frames may omit system chrome; full-screen captures require review. This diagnostic does not establish physical iPhone behavior."]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                let attachment = XCTAttachment(string: text); attachment.name = "connected-keyboard-shell-measurements.json"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        // Set the appearance before leaving the containing App, but do not
        // focus its ASCII-only HEX field until Safari has proved activation.
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["定制"].waitForExistence(timeout: 8)); app.tabBars.buttons["定制"].tap()
        let entry = elements(app, identifier: "custom.edit.backgroundColor").firstMatch
        reveal(entry, in: app); XCTAssertTrue(entry.isHittable); entry.tap()
        let blue = app.buttons["#558DF2"]
        reveal(blue, in: app); XCTAssertTrue(blue.isHittable); blue.tap()
        try enableKeyboardInSystemSettings()

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        for title in ["Continue", "Continue", "Start Browsing", "Not Now"] {
            if safari.buttons[title].exists && safari.buttons[title].isHittable { safari.buttons[title].tap() }
        }
        // The workflow opens this existing local HTTP fixture before the test.
        let fieldLabel = NSPredicate(format: "label == %@", "Safari search size check")
        let search = safari.webViews.searchFields.matching(fieldLabel).firstMatch
        let fallback = safari.webViews.textFields.matching(fieldLabel).firstMatch
        let safariField = search.waitForExistence(timeout: 4) ? search : fallback
        guard safariField.waitForExistence(timeout: 5) else {
            throw unavailable("Safari HTTP fixture was not prepared", in: safari)
        }
        safariField.tap()
        let focused = safari.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "Editing: Safari search size check")).firstMatch
        guard focused.waitForExistence(timeout: 3) else {
            throw unavailable("The Safari DOM field, rather than the address bar, must own focus", in: safari)
        }
        try sequence(in: safari, field: safariField, host: "safari-search-field")
        // The actual App field uses asciiCapable. Some system keyboards omit
        // Emoji or the picker for that trait. Record a restriction explicitly;
        // never substitute the noninteractive appearance-preview keys.
        app.activate()
        let field = app.textFields.firstMatch
        reveal(field, in: app); XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        try sequence(in: app, field: field, host: "app-actual-hex-field", permitsASCIIRestriction: true)
        XCTAssertTrue(discrepancies.isEmpty, "Connected host shell is inconsistent across transitions:\n" + discrepancies.joined(separator: "\n"))
    }
    func testCurrentRoundProductionSettingsClipboardAndLongPressInInstalledExtension() throws {
        continueAfterFailure = false; started = Date()
        let app = clear; app.launch()
        defer { screen("round62-final"); attachTree(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari"), "round62-final") }
        XCTAssertTrue(app.tabBars.buttons["输入"].waitForExistence(timeout: 8)); app.tabBars.buttons["输入"].tap()
        let clipboardSettings = elements(app, identifier: "input.clipboard").firstMatch
        reveal(clipboardSettings, in: app); clipboardSettings.tap()
        let automatic = elements(app, identifier: "clipboard.automatic").firstMatch
        reveal(automatic, in: app)
        let autoSwitch = automatic.switches.firstMatch.exists ? automatic.switches.firstMatch : app.switches.firstMatch
        if autoSwitch.value as? String == "0" {
            (autoSwitch.switches.firstMatch.exists ? autoSwitch.switches.firstMatch : autoSwitch).tap()
        }
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["定制"].tap()
        func open(_ item: String) {
            let row = elements(app, identifier: "custom.edit." + item).firstMatch
            reveal(row, in: app); XCTAssertTrue(row.isHittable); row.tap()
        }
        func back() { app.navigationBars.buttons.firstMatch.tap() }
        func actualSliderFraction(_ slider: XCUIElement) throws -> Double {
            let raw = try XCTUnwrap(slider.value as? String)
            let number = try XCTUnwrap(Double(raw.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)))
            let value = raw.contains("%") || number > 1 ? number / 100 : number
            XCTAssertTrue((0...1).contains(value), "Read the slider's actual App value, not the imprecise drag target")
            return value
        }
        open("keyGlass")
        let glass = app.sliders["appearance.strength.keyGlass"]
        glass.adjust(toNormalizedSliderPosition: 0.9)
        let expectedGlass = try actualSliderFraction(glass); back()
        open("keyColor"); let blue = app.buttons["#558DF2"]; reveal(blue, in: app); blue.tap(); back()
        open("candidateColor"); let orange = app.buttons["#E3AC72"]; reveal(orange, in: app); orange.tap(); back()
        open("candidateSize"); app.segmentedControls["custom.candidateTextSize"].buttons["特大"].tap(); back()
        let hand = app.segmentedControls["custom.hand"]; reveal(hand, in: app); hand.buttons["标准"].tap()
        let height = app.sliders["custom.keyHeight"]; reveal(height, in: app); height.adjust(toNormalizedSliderPosition: 0.85)
        let expectedHeight = (44 + 14 * (try actualSliderFraction(height))).rounded()
        let vibration = elements(app, identifier: "custom.vibration").firstMatch
        reveal(vibration, in: app)
        let toggle = vibration.switches.firstMatch.exists ? vibration.switches.firstMatch : app.switches.firstMatch
        XCTAssertTrue(toggle.isHittable)
        if toggle.value as? String == "0" {
            (toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle).tap()
        }
        let mode = app.segmentedControls["custom.vibrationMode"]; reveal(mode, in: app); mode.buttons["柔和"].tap()
        let intensity = app.sliders["custom.vibrationIntensity"]; reveal(intensity, in: app)
        intensity.adjust(toNormalizedSliderPosition: 0.75)
        let expectedIntensity = try actualSliderFraction(intensity)
        let senderValues: [String: Any] = ["keyGlassStrength": expectedGlass, "keyHeight": expectedHeight, "vibrationIntensity": expectedIntensity, "vibrationMode": "soft"]
        let sender = try JSONSerialization.data(withJSONObject: senderValues)
        let senderAttachment = XCTAttachment(data: sender, uniformTypeIdentifier: "public.json")
        senderAttachment.name = "round66-app-sender-values.json"; senderAttachment.lifetime = .keepAlways; add(senderAttachment)
        try enableKeyboardInSystemSettings()
        // Match this user's already-enabled setting on the disposable simulator.
        // Only the real Settings switch can establish extension full access.
        let settingsApp = XCUIApplication(bundleIdentifier: "com.apple.Preferences"); settingsApp.activate()
        try tapSettingsText("澈", in: settingsApp)
        let access = settingsApp.switches.firstMatch
        XCTAssertTrue(access.waitForExistence(timeout: 5))
        if access.value as? String == "0" {
            // iOS Settings exposes a row-sized Switch containing the actual
            // thumb. The row centre hits its label and does not toggle it.
            (access.switches.firstMatch.exists ? access.switches.firstMatch : access).tap()
            let allow = settingsApp.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
        let accessEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: access)
        let accessResult = XCTWaiter.wait(for: [accessEnabled], timeout: 5)
        if accessResult != .completed { attachTree(settingsApp, "round62-full-access-not-enabled") }
        XCTAssertEqual(accessResult, .completed, "Disposable simulator must match the user's enabled full-access setting")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari"); safari.activate()
        for title in ["Continue", "Continue", "Start Browsing", "Not Now"] {
            if safari.buttons[title].exists && safari.buttons[title].isHittable { safari.buttons[title].tap() }
        }
        let predicate = NSPredicate(format: "label == %@", "Safari search size check")
        let search = safari.webViews.searchFields.matching(predicate).firstMatch
        let field = search.waitForExistence(timeout: 4) ? search : safari.webViews.textFields.matching(predicate).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        try choose("澈", in: safari)
        if !key(safari, "j").waitForExistence(timeout: 8) { throw unavailable("Selected custom keyboard did not expose its real J key", in: safari) }
        func evidence() -> [String: Any] {
            let raw = control(safari, "clear.keyboard.runtime").value as? String ?? "{}"
            return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        }
        func awaitEvidence(_ reason: String, _ condition: @escaping ([String: Any]) -> Bool) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in condition(evidence()) }, object: nil)
            let result = XCTWaiter.wait(for: [expectation], timeout: 8)
            let value = evidence()
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print("ROUND62_RUNTIME " + reason + " " + text)
                let attachment = XCTAttachment(string: text); attachment.name = "round62-runtime-" + reason
                attachment.lifetime = .keepAlways; add(attachment)
            }
            if result != .completed { screen("round62-failed-condition"); attachTree(safari, "round62-failed-condition") }
            XCTAssertEqual(result, .completed, reason)
        }
        awaitEvidence("Actual appex must consume all App controls through production storage") { value in
            guard let settings = value["settings"] as? [String: Any] else { return false }
            return value["fullAccess"] as? Bool == true && value["sharedContainerAvailable"] as? Bool == true &&
                settings["keyColorHex"] as? String == "#558DF2" && settings["candidateColorHex"] as? String == "#E3AC72" &&
                settings["candidateTextSize"] as? String == "extraLarge" && settings["vibrationEnabled"] as? Bool == true &&
                settings["automaticClipboard"] as? Bool == true && settings["hand"] as? String == "full" &&
                abs((settings["keyGlassStrength"] as? Double ?? -1) - expectedGlass) <= 0.011 &&
                abs((settings["keyHeight"] as? Double ?? -1) - expectedHeight) < 0.1 &&
                abs((settings["vibrationIntensity"] as? Double ?? -1) - expectedIntensity) <= 0.011 &&
                settings["vibrationMode"] as? String == "soft"
        }
        screen("round62-app-settings-received-by-actual-appex")
        let language = control(safari, "key.language")
        if language.label.hasPrefix("英文") { language.tap() }
        let j = key(safari, "j"), point = j.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.5, thenDragTo: point.withOffset(CGVector(dx: 48, dy: 0)))
        XCTAssertTrue((field.value as? String ?? "").hasSuffix("j"), "Case popup must insert exactly lowercase j without pinyin")
        control(safari, "key.123").tap()
        let seven = key(safari, "7").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        seven.press(forDuration: 0.5, thenDragTo: seven.withOffset(CGVector(dx: -48, dy: 0)))
        XCTAssertTrue((field.value as? String ?? "").hasSuffix("j⑦"))
        let bracket = key(safari, "（").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // On this verified 420pt fixture the fitted bracket popup starts at
        // the left edge. Lift into its visible ASCII-parenthesis cell, also
        // exercising direct pointing instead of only sliding below the popup.
        bracket.press(forDuration: 0.5, thenDragTo: bracket.withOffset(CGVector(dx: 96, dy: -65)))
        XCTAssertTrue((field.value as? String ?? "").hasSuffix("j⑦("), "Literal symbol must bypass Chinese punctuation remapping")
        awaitEvidence("Actual key touch must submit a view-bound UIKit haptic") { ($0["submittedHapticPulses"] as? Int ?? 0) >= 3 }
        screen("round62-literal-case-number-symbol-input")
        control(safari, "key.ABC").tap()
        let recentClose = control(safari, "clipboard.recent.close")
        if recentClose.exists && recentClose.isHittable { recentClose.tap() }
        let source = control(safari, "toolbar.clipboard"), destination = control(safari, "toolbar.appearance")
        source.press(forDuration: 0.8, thenDragTo: destination)
        awaitEvidence("Toolbar hold enters editing and persists the reordered tools") {
            (($0["settings"] as? [String: Any])?["toolbar"] as? [String]) == ["language", "emoji", "appearance", "clipboard"]
        }
        let finishEditing = control(safari, "toolbar.tools")
        XCTAssertEqual(finishEditing.label, "完成工具栏编辑")
        finishEditing.tap()
        control(safari, "toolbar.appearance").tap()
        let colorRow = control(safari, "keyboard.appearance.keyColor")
        XCTAssertTrue(colorRow.waitForExistence(timeout: 3)); colorRow.tap()
        let localOrange = control(safari, "keyboard.swatch.#E3AC72")
        for _ in 0..<4 { if localOrange.isHittable { break }; control(safari, "keyboard.appearance.panel").swipeUp() }
        XCTAssertTrue(localOrange.isHittable); localOrange.tap()
        awaitEvidence("Keyboard panel button writes actual model and persists") { (($0["settings"] as? [String: Any])?["keyColorHex"] as? String) == "#E3AC72" }
        control(safari, "toolbar.tools").tap()
        screen("round62-native-settings-live-on-keyboard")
        // Copy in the App process while Safari's extension is suspended, then
        // return to the existing focused editor without rebuilding a fake surface.
        app.activate(); app.tabBars.buttons["定制"].tap(); open("keyColor")
        let hex = app.textFields["appearance.hex"]; reveal(hex, in: app); hex.tap()
        hex.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3)); copy.tap()
        safari.activate()
        XCTAssertTrue(key(safari, "j").waitForExistence(timeout: 8))
        awaitEvidence("Foreground copy must persist in the real extension history") { ($0["clipboardItems"] as? Int ?? 0) > 0 }
        let recentHistory = control(safari, "clipboard.recent.history")
        if recentHistory.exists && recentHistory.isHittable { recentHistory.tap() }
        else { control(safari, "toolbar.clipboard").tap() }
        XCTAssertTrue(control(safari, "clipboard.panel").waitForExistence(timeout: 4))
        screen("round62-copied-content-in-real-extension-history")
        let copied = root(in: safari).descendants(matching: .any).matching(NSPredicate(format: "label == %@", "#E3AC72")).firstMatch
        XCTAssertTrue(copied.waitForExistence(timeout: 3)); copied.tap()
        XCTAssertTrue((field.value as? String ?? "").hasSuffix("#E3AC72"), "Stored copy must insert into the real Safari editor")
        let report = try JSONSerialization.data(withJSONObject: evidence(), options: [.prettyPrinted, .sortedKeys])
        let result = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
        result.name = "round62-production-extension-evidence.json"; result.lifetime = .keepAlways; add(result)
    }

}
