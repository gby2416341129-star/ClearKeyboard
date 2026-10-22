import XCTest
import UIKit

/// Diagnostic of the installed .appex through the system keyboard picker.
/// No local KeyboardViewController, inputView override or simulated shell is used.
@MainActor final class KeyboardShellUITests: XCTestCase {
    private enum Source: String { case english, emoji }
    private let appID = ProcessInfo.processInfo.environment["CLEAR_SHELL_APP_BUNDLE_ID"] ?? "com.example.clearkeyboard"
    private var samples: [[String: Any]] = []
    private var discrepancies: [String] = []
    private var started = Date()
    private var clear: XCUIApplication { XCUIApplication(bundleIdentifier: appID) }
    private func elements(_ app: XCUIApplication, identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }
    private func key(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        elements(app, identifier: "key.text." + name).firstMatch
    }
    private func bounded() {
        XCTAssertLessThan(Date().timeIntervalSince(started), 220, "Connected extension diagnostic exceeded its bounded interaction budget")
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
    private func globe(in app: XCUIApplication) -> XCUIElement {
        let query = app.buttons.matching(NSPredicate(format:
            "label CONTAINS[c] 'Next keyboard' OR label CONTAINS[c] 'Switch keyboard' OR label CONTAINS '下一个键盘'"))
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5), "System keyboard picker is unavailable\n" + app.debugDescription)
        let visible = query.allElementsBoundByIndex.filter(\.isHittable)
        return visible.max(by: { $0.frame.midY < $1.frame.midY }) ?? query.firstMatch
    }
    private func choose(_ label: String, in app: XCUIApplication) {
        bounded()
        globe(in: app).press(forDuration: 0.8)
        let predicate = label == "English"
            ? NSPredicate(format: "label BEGINSWITH[c] %@", label)
            : NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + " ")
        let query = app.descendants(matching: .any).matching(predicate)
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 4), "Keyboard menu target missing: " + label + "\n" + app.debugDescription)
        // The containing App also has a tab called 澈. Require a visible menu
        // item near the keyboard rather than accidentally tapping that tab.
        let visible = query.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.midY > app.frame.height * 0.4 }
        let target = visible.max(by: { $0.frame.midY < $1.frame.midY })
        XCTAssertNotNil(target, "No hittable system keyboard menu item for " + label)
        target?.tap()
    }
    private func selectNative(_ source: Source, in app: XCUIApplication, host: String) {
        choose(source == .english ? "English" : "Emoji", in: app)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !self.key(app, "q").exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "The installed custom keyboard did not yield to " + source.rawValue)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 4), "Native keyboard accessibility frame is missing")
        if source == .english {
            let nativeQ = keyboard.keys.matching(NSPredicate(format: "label == 'q' OR label == 'Q'")).firstMatch
            XCTAssertTrue(nativeQ.waitForExistence(timeout: 4), "English was not confirmed by an actual native Q key")
        } else {
            let emojiProof = keyboard.descendants(matching: .any).matching(NSPredicate(format:
                "label == 'ABC' OR label CONTAINS[c] 'Search Emoji' OR label CONTAINS[c] 'Frequently Used' OR label CONTAINS[c] 'Recents'"))
            XCTAssertTrue(emojiProof.firstMatch.waitForExistence(timeout: 4), "Emoji keyboard could not be positively identified\n" + app.debugDescription)
        }
        screen(host + "-native-" + source.rawValue)
    }
    private func ensureCustomEnglish(_ app: XCUIApplication) {
        let language = elements(app, identifier: "key.language").firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5), "The actual extension language control is missing")
        if language.label.contains("中文") { language.tap() }
        XCTAssertTrue(language.label.contains("英文") || language.label.lowercased().contains("english"),
                      "Literal connection proof needs the extension's English mode")
    }
    private func captureCustom(_ app: XCUIApplication, field: XCUIElement, name: String) throws -> (CGRect, CGRect) {
        bounded()
        XCTAssertTrue(key(app, "q").waitForExistence(timeout: 8), "Installed keyboard keys did not appear\n" + app.debugDescription)
        ensureCustomEnglish(app)
        let root = elements(app, identifier: "clear.keyboard.root").firstMatch
        let runtime = elements(app, identifier: "clear.keyboard.runtime").firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 4), "Actual extension root AX bounds unavailable")
        XCTAssertTrue(runtime.waitForExistence(timeout: 4), "Actual .appex metadata unavailable; local preview is not acceptable proof")
        let payload = try XCTUnwrap(runtime.value as? String, "The DEBUG extension runtime element must expose JSON")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(metadata["bundleExtension"] as? String, "appex")
        let identifier = try XCTUnwrap(metadata["bundleIdentifier"] as? String)
        XCTAssertTrue(identifier.hasPrefix(appID + "."), "This is not the containing App's installed extension")
        XCTAssertGreaterThan((metadata["pid"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertEqual(metadata["hostActive"] as? Bool, true)
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
    private func sequence(in app: XCUIApplication, field: XCUIElement, host: String) throws {
        selectNative(.english, in: app, host: host)
        choose("澈", in: app)
        let english = try captureCustom(app, field: field, name: host + "-english-to-custom")
        selectNative(.emoji, in: app, host: host)
        choose("澈", in: app)
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
            let report: [String: Any] = ["schema": 1, "samples": samples, "geometryDiscrepancies": discrepancies,
                "runtimeOS": UIDevice.current.systemVersion, "elapsedSeconds": Date().timeIntervalSince(started),
                "verification": "installed-extension-system-picker-and-real-host-input",
                "nativeChromeGeometryFixed": false, "simulatedChromeUsed": false,
                "limits": "AX keyboard frames may omit system chrome; full-screen captures require review. This diagnostic does not establish physical iPhone behavior."]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                let attachment = XCTAttachment(string: text); attachment.name = "connected-keyboard-shell-measurements.json"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["定制"].waitForExistence(timeout: 8)); app.tabBars.buttons["定制"].tap()
        let entry = elements(app, identifier: "custom.edit.backgroundColor").firstMatch
        reveal(entry, in: app); XCTAssertTrue(entry.isHittable); entry.tap()
        let blue = app.buttons["#558DF2"]
        reveal(blue, in: app); XCTAssertTrue(blue.isHittable); blue.tap()
        let field = app.textFields.firstMatch
        reveal(field, in: app); XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        try sequence(in: app, field: field, host: "app-actual-hex-field")

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        for title in ["Continue", "Continue", "Start Browsing", "Not Now"] {
            if safari.buttons[title].exists && safari.buttons[title].isHittable { safari.buttons[title].tap() }
        }
        // The workflow opens this existing local HTTP fixture before the test.
        let search = safari.webViews.searchFields.matching(identifier: "Safari search size check").firstMatch
        let fallback = safari.webViews.textFields.matching(identifier: "Safari search size check").firstMatch
        let safariField = search.waitForExistence(timeout: 4) ? search : fallback
        XCTAssertTrue(safariField.waitForExistence(timeout: 5), "Safari HTTP fixture was not prepared\n" + safari.debugDescription)
        safariField.tap()
        try sequence(in: safari, field: safariField, host: "safari-search-field")
        XCTAssertTrue(discrepancies.isEmpty, "Connected host shell is inconsistent across transitions:\n" + discrepancies.joined(separator: "\n"))
    }
}
