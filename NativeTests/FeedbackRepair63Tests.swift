import XCTest
import UIKit

@MainActor final class FeedbackRepair63Tests: XCTestCase {
    private final class Document: KeyboardDocument {
        var text = "", cursor = 0, selectedText = ""
        let documentIdentity = UUID().uuidString
        var contextBefore: String { String(text.prefix(cursor)) }
        var contextAfter: String { String(text.dropFirst(cursor)) }
        let enterTitle = "换行", needsGlobe = false, fullAccess = false, prefersEnglish = false
        let capitalization = UITextAutocapitalizationType.none
        var usesLocalPinyinComposition: Bool { true }
        func insert(_ value: String) {
            text = contextBefore + value + contextAfter; cursor += value.count
        }
        func deleteBackward() {
            guard cursor > 0 else { return }
            let right = contextAfter; var left = contextBefore; left.removeLast(); cursor -= 1; text = left + right
        }
        func moveCursor(_ offset: Int) { cursor = min(text.count, max(0, cursor + offset)) }
        func beginTrackpad() {}
        func trackCursor(translation: CGPoint) {}
        func endTrackpad() {}
        func nextKeyboard() {}
        func setMarkedText(_ text: String) {}
        func commitMarkedText(_ text: String) { insert(text) }
        func unmarkText() {}
        func clearInput() -> DeletedInput? { nil }
        func restoreInput(_ value: DeletedInput) -> Bool { false }
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func fixture(allTools: Bool = true) -> (Document, KeyboardModel, KeyboardSurface, UserDefaults) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let doc = Document(); var settings = KeyboardSettings()
        settings.toolbar = allTools ? ToolbarTool.allCases : [.language]
        let model = KeyboardModel(document: doc, settings: settings, defaults: defaults, wordLookup: { _, _, _ in [] })
        let surface = KeyboardSurface(model: model); surface.frame = CGRect(x: 0, y: 0, width: 420, height: 310)
        surface.layoutIfNeeded(); return (doc, model, surface, defaults)
    }
    private func button(_ id: String, in surface: UIView) throws -> UIButton {
        try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
    func testAllToolsAddAndRemoveImmediatelyUsingTheSameEditorButtons() throws {
        let (_, model, surface, defaults) = fixture(allTools: false)
        surface.showToolbarEditor()
        let tools = ToolbarTool.allCases.filter { $0 != .language }
        let tiles = try tools.map { try button("toolbar.editor." + $0.rawValue, in: surface) }
        for (tool, tile) in zip(tools, tiles) {
            tile.sendActions(for: .touchUpInside); surface.layoutIfNeeded()
            XCTAssertTrue(model.settings.toolbar.contains(tool))
            XCTAssertNotNil(views(surface).first { $0.accessibilityIdentifier == "toolbar." + tool.rawValue })
        }
        for (tool, tile) in zip(tools, tiles) {
            tile.sendActions(for: .touchUpInside); surface.layoutIfNeeded()
            XCTAssertFalse(model.settings.toolbar.contains(tool))
            XCTAssertNil(views(surface).first { $0.accessibilityIdentifier == "toolbar." + tool.rawValue })
        }
        XCTAssertEqual(SettingsStore(defaults: defaults).load().toolbar, [.language])
    }
    func testToolbarScrollPositionSurvivesANewSurface() throws {
        let old = UserDefaults.standard.object(forKey: "clear.toolbar.offset.v1")
        defer { UserDefaults.standard.set(old, forKey: "clear.toolbar.offset.v1") }
        let (_, _, surface, _) = fixture()
        let scroll = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "toolbar.shortcuts" } as? UIScrollView)
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
        scroll.setContentOffset(CGPoint(x: 65, y: 0), animated: false)
        surface.scrollViewDidEndDragging(scroll, willDecelerate: false)
        let (_, _, restored, _) = fixture()
        let next = try XCTUnwrap(views(restored).first { $0.accessibilityIdentifier == "toolbar.shortcuts" } as? UIScrollView)
        XCTAssertEqual(next.contentOffset.x, 44, accuracy: 1)
    }
    func testPanelToggleSwitchAndRepeatedColorOpeningUseOnePreview() throws {
        let (_, _, surface, _) = fixture()
        for _ in 0..<5 {
            try button("toolbar.keyColor", in: surface).sendActions(for: .touchUpInside)
            XCTAssertEqual(views(surface).compactMap { $0 as? KeyboardAppearancePanelView }.first?.selected, .keyColor)
            XCTAssertEqual(views(surface).compactMap { $0 as? KeyboardAppearancePreview }.count, 1)
            try button("toolbar.textColor", in: surface).sendActions(for: .touchUpInside)
            XCTAssertEqual(views(surface).compactMap { $0 as? KeyboardAppearancePanelView }.first?.selected, .candidateColor)
            try button("toolbar.textColor", in: surface).sendActions(for: .touchUpInside)
            XCTAssertTrue(views(surface).compactMap { $0 as? KeyboardAppearancePanelView }.isEmpty)
        }
        try button("toolbar.emoji", in: surface).sendActions(for: .touchUpInside)
        try button("toolbar.keyGlass", in: surface).sendActions(for: .touchUpInside)
        XCTAssertEqual(views(surface).compactMap { $0 as? KeyboardAppearancePanelView }.first?.selected, .keyGlass)
    }
    func testColorAndResetReuseTheNativeGlassEffect() {
        let lens = LiquidGlassView(radius: 8, keycap: true)
        let effect = lens.effect
        for index in 0..<20 {
            lens.configure(tint: index.isMultiple(of: 2) ? .systemBlue : nil,
                           strength: Double(index) / 20, fallback: .secondarySystemBackground)
            XCTAssertTrue(effect === lens.effect, "Color/opacity must not allocate a native glass effect for every key on every change")
        }
    }
    func testPreviewShiftAndDeleteStayBoundedAfterRepeatedColorReset() {
        let preview = KeyboardAppearancePreview(); preview.frame = CGRect(x: 0, y: 0, width: 320, height: 170)
        var settings = KeyboardSettings()
        for index in 0..<12 {
            settings.keyColorHex = index.isMultiple(of: 2) ? "#558DF2" : nil
            preview.apply(settings); preview.layoutIfNeeded()
            for image in views(preview).compactMap({ $0 as? UIImageView }) where image.image != nil && image.superview?.accessibilityIdentifier == "key.face" {
                XCTAssertEqual(image.contentMode, .scaleAspectFit)
                XCTAssertLessThanOrEqual(image.bounds.width, 32)
                XCTAssertTrue(image.superview!.bounds.insetBy(dx: -0.01, dy: -0.01).contains(image.frame))
            }
        }
    }
    func testLettersOfferCaseAlternativesInBothInputLanguages() throws {
        let key = try XCTUnwrap(KeyboardLayout.rows(page: .letters, uppercase: false, globe: false).first?.keys.first)
        for language in [InputLanguage.chinese, .english] {
            XCTAssertEqual(Set(KeyAlternatives.choices(for: key, language: language)), Set(["Q", "q"]))
        }
    }
    func testBothPopupSelectionPathsReachEveryChoiceAtBothEdges() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 310))
        for x in [CGFloat(0), CGFloat(380)] {
            for values in [["壹", "❶", "①", "1"], KeyAlternatives.values(for: "（")] {
                let anchor = CGRect(x: x, y: 75, width: 40, height: 50)
                let origin = CGPoint(x: anchor.midX, y: anchor.midY)
                let popup = KeyChoicePopup(choices: values, initial: values.count - 1, origin: origin, anchor: anchor, host: host, accent: .systemBlue)
                let base = popup.selectedIndex, cell = (popup.bounds.width - 8) / CGFloat(values.count)
                for index in popup.choices.indices {
                    let below = CGPoint(x: origin.x + CGFloat(index - base) * cell, y: origin.y)
                    XCTAssertTrue(host.bounds.contains(below))
                    popup.update(at: below); XCTAssertEqual(popup.selectedValue, popup.choices[index])
                    popup.update(at: CGPoint(x: popup.frame.minX + 4 + (CGFloat(index) + 0.5) * cell, y: popup.frame.midY))
                    XCTAssertEqual(popup.selectedValue, popup.choices[index])
                }
            }
        }
    }
    func testLongArticleIsCapturedAndInlinePreviewRetainsAllText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "这是一篇完整的长文章。", count: 1200)
        let capture = ClipboardCapture(defaults: UserDefaults(suiteName: UUID().uuidString)!, makeStore: { ClipboardStore(url: url) })
        var captures = 0; capture.onCapture = { captures += 1 }; capture.acceptText(text)
        XCTAssertEqual(ClipboardStore(url: url).clips.first?.text, text); XCTAssertEqual(captures, 1)
        let inline = ClipboardInlinePreview(); inline.frame = CGRect(x: 0, y: 0, width: 200, height: 38); inline.show(text)
        XCTAssertEqual(inline.text, text); XCTAssertGreaterThan(inline.contentSize.width, 200)
    }
    func testTapMultiSelectionAndCancellationUpdateOnlyOwnedEditorText() throws {
        let (doc, model, _, _) = fixture()
        doc.text = "原有尾巴"; doc.cursor = 2
        let panel = ClipboardPanel(model: model); panel.selectText("甲乙丙丁")
        XCTAssertTrue(panel.setSelection([0, 2])); XCTAssertEqual(doc.text, "原有甲丙尾巴")
        XCTAssertTrue(panel.setSelection([2])); XCTAssertEqual(doc.text, "原有丙尾巴")
        XCTAssertTrue(panel.setSelection([1, 2, 3])); XCTAssertEqual(doc.text, "原有乙丙丁尾巴")
        XCTAssertTrue(panel.setSelection([])); XCTAssertEqual(doc.text, "原有尾巴")
        XCTAssertTrue(panel.setSelection([0])); doc.insert("其他")
        XCTAssertFalse(panel.setSelection([])); XCTAssertEqual(doc.text, "原有甲其他尾巴")
    }
    func testCompactTokenGapsAndRepeatedSingleTapSelection() throws {
        let (doc, model, _, _) = fixture()
        let panel = ClipboardPanel(model: model); panel.frame = CGRect(x: 0, y: 0, width: 360, height: 250)
        panel.selectText("甲乙丙丁"); panel.layoutIfNeeded()
        let words = try XCTUnwrap(views(panel).first { $0.accessibilityIdentifier == "clipboard.selection.words" } as? UICollectionView)
        words.layoutIfNeeded()
        let first = try XCTUnwrap(words.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let second = try XCTUnwrap(words.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        XCTAssertEqual(second.frame.minX - first.frame.maxX, 4, accuracy: 0.1)
        panel.collectionView(words, didSelectItemAt: IndexPath(item: 1, section: 0)); XCTAssertEqual(doc.text, "乙")
        panel.collectionView(words, didSelectItemAt: IndexPath(item: 3, section: 0)); XCTAssertEqual(doc.text, "乙丁")
        panel.collectionView(words, didSelectItemAt: IndexPath(item: 1, section: 0)); XCTAssertEqual(doc.text, "丁")
    }
}
