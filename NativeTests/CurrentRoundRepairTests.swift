import XCTest
import UIKit
import CoreText

@MainActor final class CurrentRoundRepairTests: XCTestCase {
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private final class Document: KeyboardDocument {
        var contextBefore = "", contextAfter = "", selectedText = ""
        let documentIdentity = UUID().uuidString
        let enterTitle = "换行", needsGlobe = false, fullAccess = true, prefersEnglish = false
        let capitalization = UITextAutocapitalizationType.none
        var usesLocalPinyinComposition = true
        func insert(_ text: String) { contextBefore += text }
        func deleteBackward() { if !contextBefore.isEmpty { contextBefore.removeLast() } }
        func moveCursor(_ offset: Int) {}
        func beginTrackpad() {}
        func trackCursor(translation: CGPoint) {}
        func endTrackpad() {}
        func nextKeyboard() {}
        func setMarkedText(_ text: String) {}
        func commitMarkedText(_ text: String) { contextBefore += text }
        func unmarkText() {}
        func clearInput() -> DeletedInput? { nil }
        func restoreInput(_ value: DeletedInput) -> Bool { false }
    }
    func testBottomRowsBalanceAndPreserveSystemLetterPositions() {
        for language in [InputLanguage.chinese, .english] {
            for page in [KeyboardPage.letters, .numbers, .symbols] {
                for globe in [true, false] {
                    let rows = KeyboardLayout.rows(page: page, globe: globe, language: language)
                    for row in rows { XCTAssertEqual(row.insetUnits * 2 + row.keys.reduce(0) { $0 + $1.units }, 10, accuracy: 0.00001) }
                    let bottom = rows[3].keys, space = bottom.firstIndex { $0.action == .space }!
                    XCTAssertEqual(bottom[space - 1].label, language == .chinese ? "，" : ",")
                    XCTAssertEqual(bottom[space + 1].action, .language)
                    XCTAssertEqual(bottom.prefix(space).reduce(0) { $0 + $1.units }, bottom.suffix(from: space + 1).reduce(0) { $0 + $1.units }, accuracy: 0.00001)
                    XCTAssertEqual(bottom[space - 1].alternatives, language == .chinese ? ["，", "。"] : [",", "."])
                }
            }
        }
        let rows = KeyboardLayout.rows(page: .letters)
        XCTAssertEqual(rows[0].keys.map(\.label).joined(), "qwertyuiop")
        XCTAssertEqual(rows[1].keys.map(\.label).joined(), "asdfghjkl")
        XCTAssertEqual(rows[1].insetUnits, 0.5)
    }
    func testVariantsHaveCorrectCaseOrderAndNeverBecomePinyin() throws {
        let j = KeyboardKey("J", .text("j"))
        XCTAssertEqual(KeyAlternatives.choices(for: j, language: .chinese), ["J", "j"])
        XCTAssertEqual(KeyAlternatives.choices(for: j, language: .english), ["J", "j"])
        XCTAssertEqual(KeyAlternatives.values(for: "7"), ["柒", "❼", "⑦", "7"])
        XCTAssertTrue(KeyAlternatives.values(for: "（").contains("《"))
        let suite = "clear.round.literal." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let document = Document(); var settings = KeyboardSettings(); settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings, defaults: defaults); defer { model.suspend() }
        for value in ["J", "j", "柒", "⑦", "(", "。"][...] { model.handle(.literal(value)) }
        XCTAssertEqual(document.contextBefore, "Jj柒⑦(。")
        XCTAssertTrue(model.composition.isEmpty)
    }
    func testLongPressLiteralsAwaitThePendingChineseCandidateWithoutLosingTheirOrder() async throws {
        let suite = "clear.round.literal-pending." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let document = Document(), releaseLookup = DispatchSemaphore(value: 0)
        var settings = KeyboardSettings()
        settings.automaticClipboard = false; settings.learnChoices = false; settings.predictions = false
        let model = KeyboardModel(document: document, settings: settings, defaults: defaults, wordLookup: { engine, raw, preferred in
            // Keep the final word result unavailable while release events enter
            // the production candidate barrier. The sentence worker and its
            // main-queue delivery still follow the ordinary asynchronous path.
            if raw == "nihao" { _ = releaseLookup.wait(timeout: .now() + 5) }
            return engine.immediateCandidates(raw, preferred: preferred)
        })
        defer { releaseLookup.signal(); model.suspend(); defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<400 {
            if model.engineState == "离线就绪" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.engineState, "离线就绪")
        // Do not yield between the last pinyin contact and the held-key release:
        // a completed background query has not yet delivered its current row.
        for letter in "nihao" { model.handle(.text(String(letter))) }
        XCTAssertFalse(model.candidatesAreCurrent)
        let values = ["J", "j", "柒", "⑦", "(", "。"]
        for value in values { model.handle(.literal(value)) }
        XCTAssertEqual(model.composition.raw, "nihao", "A literal choice must wait rather than flush unconverted pinyin")
        XCTAssertEqual(document.contextBefore, "", "No suffix may overtake the pending Chinese conversion")
        releaseLookup.signal()
        for _ in 0..<400 {
            if model.composition.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.composition.isEmpty)
        XCTAssertEqual(document.contextBefore, "你好" + values.joined(), "Convert the draft once, then insert every literal choice in order")
    }
    func testEveryCustomizationFieldSurvivesSharedSnapshotAndLegacyDecode() throws {
        var expected = KeyboardSettings()
        expected.keyGlassStrength = 0.93; expected.keyColorHex = "#558DF2"; expected.candidateColorHex = "#E3AC72"
        expected.candidateTextSize = .extraLarge; expected.keyHeight = 57
        expected.vibrationEnabled = true; expected.vibrationIntensity = 0.8
        expected.hand = .right; expected.oneHandWidth = 0.7
        expected.toolbar = [.language, .compatibility, .phrases, .oneHand, .clipboard]
        expected.localPinyinComposition = true; expected.automaticClipboard = false; expected.clipboardLifetimeHours = 720
        let snapshot = AppearanceSnapshot(settings: expected)
        let decoded = try JSONDecoder().decode(AppearanceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let actual = decoded.applying(to: KeyboardSettings())
        XCTAssertEqual(AppearanceSnapshot(settings: actual), snapshot)
        XCTAssertEqual(actual.toolbar, expected.toolbar); XCTAssertEqual(actual.hand, expected.hand)
        XCTAssertEqual(actual.automaticClipboard, false); XCTAssertEqual(actual.clipboardLifetimeHours, 720)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for key in ["hand", "oneHandWidth", "toolbar", "localPinyinComposition", "automaticClipboard", "clipboardLifetimeHours"] { legacy.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(AppearanceSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.applying(to: expected).toolbar, expected.toolbar)
        XCTAssertEqual(old.applying(to: expected).hand, .right)
    }
    func testFailedClipboardReadRetriesOnReactivationAndDoesNotLoopWhileVisible() throws {
        let suite = "clear.round.clipboard." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("clipboard.json")
        var payload: String? = nil, reads = 0
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: url) }, changeCount: { 7 }, hasStrings: { true }, readText: { reads += 1; return payload })
        defer { capture.stop() }
        capture.activate(settings: KeyboardSettings(), allowed: true)
        for _ in 0..<10 { capture.captureIfChanged() }
        XCTAssertEqual(reads, 1)
        capture.stop(); payload = "recovered copy at the same revision"
        capture.activate(settings: KeyboardSettings(), allowed: true)
        XCTAssertEqual(reads, 2); XCTAssertEqual(ClipboardStore(url: url).clips.first?.text, payload)
    }
    func testNativeAppearanceRowsAndControlsWriteThroughAndKeepHitTargets() throws {
        var value = KeyboardSettings()
        let panel = KeyboardAppearancePanelView(current: { value }, save: { value = $0 })
        panel.frame = CGRect(x: 0, y: 0, width: 393, height: 250); panel.layoutIfNeeded()
        for item in AppearanceItem.allCases {
            let row = try XCTUnwrap(views(panel).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "keyboard.appearance." + item.rawValue })
            row.sendActions(for: .touchUpInside); panel.layoutIfNeeded()
            switch item {
            case .keyGlass:
                let slider = try XCTUnwrap(views(panel).compactMap { $0 as? UISlider }.first)
                slider.value = 0.9; slider.sendActions(for: .valueChanged)
                XCTAssertEqual(value.resolvedKeyGlassStrength, 0.9, accuracy: 0.0001)
            case .candidateSize:
                let picker = try XCTUnwrap(views(panel).compactMap { $0 as? UISegmentedControl }.first)
                picker.selectedSegmentIndex = 3; picker.sendActions(for: .valueChanged)
                XCTAssertEqual(value.candidateTextSize, .extraLarge)
            case .keyColor, .candidateColor:
                let swatch = try XCTUnwrap(views(panel).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "keyboard.swatch.#558DF2" })
                swatch.sendActions(for: .touchUpInside)
                XCTAssertEqual(value[keyPath: item.colorPath!], "#558DF2")
            }
            let back = try XCTUnwrap(views(panel).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "keyboard.appearance.back" })
            back.sendActions(for: .touchUpInside)
        }
    }
    func testActualSurfaceDirectDragExtraToolsAndNarrowClipping() throws {
        let suite = "clear.round.toolbar." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let document = Document(); var settings = KeyboardSettings(); settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings, defaults: defaults); defer { model.suspend() }
        let surface = KeyboardSurface(model: model, systemBacked: true)
        surface.frame = CGRect(x: 0, y: 0, width: 260, height: surface.desiredHeight); surface.layoutIfNeeded()
        XCTAssertTrue(surface.beginToolbarDrag(.clipboard), "Direct hold must work without opening the toolbar editor")
        let target = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "toolbar.appearance" })
        surface.performToolbarDrop(.clipboard, at: target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: surface))
        surface.finishToolbarDrag()
        XCTAssertEqual(model.settings.toolbar, [.language, .emoji, .appearance, .clipboard])
        surface.setToolPinned(.compatibility, pinned: true); surface.setToolPinned(.phrases, pinned: true)
        XCTAssertTrue(model.settings.toolbar.contains(.compatibility)); XCTAssertTrue(model.settings.toolbar.contains(.phrases))
        surface.showToolbarEditor(); surface.setNeedsLayout(); surface.layoutIfNeeded()
        for view in views(surface) { view.layoutIfNeeded() }
        let scroll = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "toolbar.shortcuts" } as? UIScrollView)
        scroll.contentOffset.x = max(0, scroll.contentSize.width - scroll.bounds.width)
        let last = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "toolbar.phrases" })
        XCTAssertGreaterThanOrEqual(last.convert(last.bounds, to: scroll).minX, scroll.bounds.minX)
        XCTAssertLessThanOrEqual(last.convert(last.bounds, to: scroll).maxX, scroll.bounds.maxX + 0.5)
    }
    func testPopupEdgesSelectionAndCancellationAtPhoneSizes() {
        for width: CGFloat in [260, 320, 393, 440] {
            let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 260))
            for x in [CGFloat(3), width / 2, width - 25] {
                let origin = CGPoint(x: x, y: 80)
                let popup = KeyChoicePopup(choices: ["柒", "❼", "⑦", "7"], initial: 3, origin: origin,
                    anchor: CGRect(x: x - 15, y: 60, width: 30, height: 50), host: host, accent: .systemBlue)
                XCTAssertGreaterThanOrEqual(popup.frame.minX, 0); XCTAssertLessThanOrEqual(popup.frame.maxX, width)
                XCTAssertEqual(popup.selectedValue, "7")
                popup.update(at: CGPoint(x: x + (x < width / 2 ? 48 : -48), y: 80))
                XCTAssertNotNil(popup.selectedValue); XCTAssertNotEqual(popup.selectedValue, "7")
                let step = (popup.bounds.width - 8) / CGFloat(popup.choices.count)
                for (index, value) in popup.choices.enumerated() {
                    popup.update(at: CGPoint(x: popup.frame.minX + 4 + (CGFloat(index) + 0.5) * step, y: popup.frame.midY))
                    XCTAssertEqual(popup.selectedValue, value, "Every visible popup option remains directly reachable at both screen edges")
                }
                popup.update(at: CGPoint(x: x, y: 180)); XCTAssertNil(popup.selectedValue)
            }
        }
    }
    func testNativeChoicePopupsAndCompatibilityAtPhoneSizeInBothThemes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        let suite = "clear.round.visual." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let document = Document(); var settings = KeyboardSettings(); settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings, defaults: defaults); defer { model.suspend() }
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        let surface = KeyboardSurface(model: model, systemBacked: true); host.view.addSubview(surface)
        func capture(_ name: String) async throws {
            window.layoutIfNeeded(); surface.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let value = XCTAttachment(image: image); value.name = "Round62-" + name; value.lifetime = .keepAlways; add(value)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            host.view.backgroundColor = style == .dark ? UIColor(red: 0.12, green: 0.15, blue: 0.20, alpha: 1) : UIColor(red: 0.85, green: 0.91, blue: 0.97, alpha: 1)
            let name = style == .dark ? "dark" : "light"
            surface.frame = CGRect(x: 0, y: window.bounds.height - surface.desiredHeight - 60, width: window.bounds.width, height: surface.desiredHeight)
            for (page, symbol, choices, initial) in [(KeyboardPage.letters, "j", ["J", "j"], 0),
                                                    (.numbers, "7", ["柒", "❼", "⑦", "7"], 3),
                                                    (.numbers, "（", KeyAlternatives.values(for: "（"), 4)] {
                model.handle(.page(page)); surface.layoutIfNeeded()
                let key = try XCTUnwrap(views(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .text(symbol) })
                let anchor = key.convert(key.bounds, to: surface)
                let popup = KeyChoicePopup(choices: choices, initial: initial,
                    origin: CGPoint(x: anchor.midX, y: anchor.midY), anchor: anchor, host: surface, accent: settings.accentColor)
                surface.addSubview(popup); try await capture(name + "-popup-" + (symbol == "（" ? "bracket" : symbol)); popup.removeFromSuperview()
            }
            model.handle(.page(.letters))
            for letter in "bbbhghh" { model.handle(.text(String(letter))) }
            surface.layoutIfNeeded(); try await capture(name + "-compatibility-preedit")
            let preedit = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "keyboard.localPreedit" })
            XCTAssertLessThan(preedit.bounds.width, 70, "Local spelling should use its measured width rather than an empty fixed slot")
            model.clearComposition()
        }
    }

}
