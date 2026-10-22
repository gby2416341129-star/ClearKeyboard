import XCTest
import UIKit

/// Diagnostic of the installed .appex through the system keyboard picker.
/// No local KeyboardViewController, inputView override or simulated shell is used.
@MainActor final class KeyboardShellUITests: XCTestCase {
    private enum Source: String { case english, emoji }
    private struct ShellCapture {
        let rootFrameAX: CGRect
        let keyboardFrameAX: CGRect?
    }
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
    private func attachJSON(_ value: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        let attachment = XCTAttachment(string: text)
        attachment.name = name + ".json"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func captureCustom(_ app: XCUIApplication, field: XCUIElement, name: String) throws -> ShellCapture {
        bounded()
        guard key(app, "q").waitForExistence(timeout: 8) else {
            throw unavailable("Installed extension keys did not appear inside clear.keyboard.root", in: app)
        }
        try ensureCustomEnglish(app)
        // Preserve actual pixels and AX before any assertion can abort XCTest.
        // Cross-process extension AX frames can be local to its own 0-origin.
        screen(name + "-before-validation")
        attachTree(app, name + "-before-validation")
        let root = self.root(in: app)
        let runtime = control(app, "clear.keyboard.runtime")
        guard root.waitForExistence(timeout: 4), runtime.waitForExistence(timeout: 4) else {
            throw unavailable("Actual extension root/.appex metadata unavailable; an App preview is not proof", in: app)
        }
        let payload = try XCTUnwrap(runtime.value as? String, "The DEBUG extension runtime element must expose JSON")
        let rawMetadata = XCTAttachment(string: payload)
        rawMetadata.name = name + "-runtime.json"; rawMetadata.lifetime = .keepAlways; add(rawMetadata)
        print("ACTUAL_EXTENSION_RUNTIME " + name + " " + payload)
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
        let keyboardFrame: CGRect? = keyboard.exists ? keyboard.frame : nil
        let q = key(app, "q"), a = key(app, "a"), z = key(app, "z")
        for element in [root, q, a, z] {
            XCTAssertTrue(element.frame.width.isFinite && element.frame.height.isFinite && element.frame.width > 0 && element.frame.height > 0)
        }
        let image = XCUIScreen.main.screenshot().image
        let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
        var sample: [String: Any] = ["name": name, "runtime": metadata,
            "screenSizePoints": [Double(UIScreen.main.bounds.width), Double(UIScreen.main.bounds.height)],
            "screenPixels": [pixelWidth, pixelHeight],
            "screenshotPixelsPerPoint": Double(pixelWidth) / Double(UIScreen.main.bounds.width),
            "rootFrameAX": jsonRect(root.frame),
            "rootFrameCoordinateSpace": "XCUI-reported-may-be-extension-local-not-verified-screen-space",
            "qFrameAX": jsonRect(q.frame), "aFrameAX": jsonRect(a.frame), "zFrameAX": jsonRect(z.frame),
            "outerFrameAvailable": keyboardFrame != nil,
            "outerFrameSource": keyboardFrame == nil ? "unavailable-no-Keyboard-AX-role" : "public-Keyboard-AX-role-not-verified-complete-system-chrome",
            "rootTopMinusKeyboardTop": NSNull(), "keyboardBottomMinusRootBottom": NSNull(),
            "geometryVerified": false, "coverageResolved": false,
            "captureCompleted": false, "qReachedFocusedHost": false,
            "nativeChromeGeometryFixed": false]
        if let keyboardFrame { sample["keyboardFrameAX"] = jsonRect(keyboardFrame) }
        else { sample["keyboardFrameAX"] = NSNull() }
        let old = field.value as? String ?? ""
        sample["hostValueBeforeQ"] = old
        let oldQ = old.lowercased().filter { $0 == "q" }.count
        let index = samples.count
        samples.append(sample)
        attachJSON(sample, name: name + "-before-q")
        // Use the real key's original tap API. Never compensate its AX position
        // with a guessed host offset, window height or the reported 17pt band.
        q.tap()
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = field.value as? String ?? ""
            return current != old && current.lowercased().filter { $0 == "q" }.count > oldQ
        }, object: nil)
        let result = XCTWaiter.wait(for: [inserted], timeout: 5)
        sample["qReachedFocusedHost"] = result == .completed
        sample["hostValueAfterQ"] = field.value as? String ?? ""
        sample["captureCompleted"] = true
        samples[index] = sample
        attachJSON(sample, name: name + "-after-q")
        screen(name + "-after-q")
        attachTree(app, name + "-after-q")
        print("CONNECTED_KEYBOARD_SHELL " + name + " qReachedFocusedHost=" + String(result == .completed) + " metadata=" + payload)
        XCTAssertEqual(result, .completed, "A real custom-keyboard Q tap did not reach the focused host")
        return ShellCapture(rootFrameAX: root.frame, keyboardFrameAX: keyboardFrame)
    }
    private func compare(_ previous: ShellCapture, _ current: ShellCapture, name: String) {
        // Compare dimensions only. Extension AX positions may be local while
        // host AX positions are global; subtracting their origins invents gaps.
        var metrics: [(String, CGFloat, CGFloat)] = [
            ("rootAXHeight", previous.rootFrameAX.height, current.rootFrameAX.height),
            ("rootAXWidth", previous.rootFrameAX.width, current.rootFrameAX.width)
        ]
        if let first = previous.keyboardFrameAX, let second = current.keyboardFrameAX {
            metrics.append(("hostKeyboardAXHeight", first.height, second.height))
            metrics.append(("hostKeyboardAXWidth", first.width, second.width))
        }
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
        guard app.wait(for: .runningForeground, timeout: 8) else {
            throw unavailable("Focused Home/return host did not enter the foreground", in: app)
        }
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
                "capturesCompleted": samples.filter { $0["captureCompleted"] as? Bool == true }.count,
                "mandatorySafariCapturesCompleted": samples.filter {
                    ($0["name"] as? String)?.hasPrefix("safari-") == true && $0["captureCompleted"] as? Bool == true
                }.count == 3,
                "geometryVerified": false, "coverageResolved": false,
                "geometryVerification": "not-verified-AX-coordinate-spaces-and-system-chrome-require-full-screen-review",
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
        if !safari.wait(for: .runningForeground, timeout: 8) {
            // One bounded relaunch may restore the already opened local URL.
            // A missing foreground is infrastructure evidence, not a DOM miss.
            safari.launch()
        }
        guard safari.wait(for: .runningForeground, timeout: 8) else {
            throw unavailable("Safari did not enter the foreground after activate and one launch", in: safari)
        }
        screen("safari-foreground-before-field")
        attachTree(safari, "safari-foreground-before-field")
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
        XCTAssertEqual(samples.filter {
            ($0["name"] as? String)?.hasPrefix("safari-") == true && $0["qReachedFocusedHost"] as? Bool == true
        }.count, 3, "All English/Emoji/focused-Home Safari transitions need real Q delivery")
        // The actual App field uses asciiCapable. Some system keyboards omit
        // Emoji or the picker for that trait. Record a restriction explicitly;
        // never substitute the noninteractive appearance-preview keys.
        app.activate()
        let field = app.textFields.firstMatch
        reveal(field, in: app); XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        try sequence(in: app, field: field, host: "app-actual-hex-field", permitsASCIIRestriction: true)
        XCTAssertTrue(discrepancies.isEmpty, "Connected host shell is inconsistent across transitions:\n" + discrepancies.joined(separator: "\n"))
    }
}

