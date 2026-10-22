import XCTest
import UIKit

@MainActor final class ToolbarRuntimeTests: XCTestCase {
    private let all: [ToolbarTool] = [.language, .clipboard, .emoji, .oneHand, .appearance]
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    @MainActor private final class Document: KeyboardDocument {
        var contextBefore = "", contextAfter = "", selectedText = ""
        let documentIdentity = UUID().uuidString
        let enterTitle = "换行", needsGlobe = false, fullAccess = false, prefersEnglish = false
        let capitalization = UITextAutocapitalizationType.none
        var usesLocalPinyinComposition = false
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
    @MainActor private final class Fixture {
        let window: UIWindow, surface: KeyboardSurface, model: KeyboardModel, document: Document
        let defaults: UserDefaults, suite: String
        weak var previousKeyWindow: UIWindow?
        init(width: CGFloat) throws {
            suite = "clear.toolbar.runtime." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            document = Document()
            var settings = KeyboardSettings(); settings.predictions = false; settings.automaticClipboard = false
            settings.toolbar = [.language, .clipboard, .emoji, .oneHand, .appearance]
            model = KeyboardModel(document: document, settings: settings, defaults: defaults)
            surface = KeyboardSurface(model: model)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
            surface.frame = CGRect(x: 16, y: 80, width: width, height: surface.desiredHeight)
            host.view.addSubview(surface)
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            // Dismiss only this surface's prompt; never erase the user's saved
            // clipboard merely to make a toolbar fixture visible.
            descendants(surface).compactMap { $0 as? UIButton }
                .first { $0.accessibilityIdentifier == "clipboard.recent.close" }?.sendActions(for: .touchUpInside)
            host.view.layoutIfNeeded(); surface.layoutIfNeeded()
        }
        func close() {
            model.suspend(); window.isHidden = true; previousKeyWindow?.makeKey()
            defaults.removePersistentDomain(forName: suite)
        }
    }
    private func button(_ tool: ToolbarTool, in surface: KeyboardSurface) throws -> UIButton {
        try XCTUnwrap(views(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "toolbar." + tool.rawValue })
    }
    private func layout(_ surface: KeyboardSurface) {
        surface.setNeedsLayout(); surface.layoutIfNeeded()
        for view in views(surface) { view.layoutIfNeeded() }
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "The local input fixture must reach its current candidate row")
    }
    func testAllFourShortcutsSurviveAndNarrowHeaderScrollsWithoutMovingBrand() throws {
        let fixture = try Fixture(width: 180); defer { fixture.close() }
        let surface = fixture.surface; layout(surface)
        XCTAssertEqual(fixture.model.settings.toolbar, all)
        for tool in all.dropFirst() { XCTAssertNotNil(try button(tool, in: surface)) }
        let scroll = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "toolbar.shortcuts" } as? UIScrollView)
        let brand = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "toolbar.tools" })
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
        let brandFrame = brand.convert(brand.bounds, to: surface)
        scroll.contentOffset.x = max(0, scroll.contentSize.width - scroll.bounds.width); layout(surface)
        let last = try button(.appearance, in: surface)
        XCTAssertTrue(scroll.convert(scroll.bounds, to: surface).intersects(last.convert(last.bounds, to: surface)))
        XCTAssertEqual(brand.convert(brand.bounds, to: surface), brandFrame)
        XCTAssertEqual(fixture.model.settings.toolbar, all)
    }
    func testDroppingOnEveryOtherIconSwapsBothDirectionsAndKeepsActiveTargetsAlive() throws {
        let fixture = try Fixture(width: 393); defer { fixture.close() }
        let surface = fixture.surface
        for from in 1..<all.count {
            for to in 1..<all.count where from != to {
                fixture.model.settings.toolbar = all; surface.showToolbarEditor(); layout(surface)
                let source = try button(all[from], in: surface), target = try button(all[to], in: surface)
                XCTAssertTrue(surface.beginToolbarDrag(all[from]))
                let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: surface)
                surface.performToolbarDrop(all[from], at: point)
                var expected = all; expected.swapAt(from, to)
                XCTAssertEqual(fixture.model.settings.toolbar, expected)
                XCTAssertTrue(try button(all[from], in: surface) === source, "A settings render must not destroy an active drag source")
                XCTAssertTrue(try button(all[to], in: surface) === target, "The drop target must survive until UIKit finishes")
                surface.finishToolbarDrag(); layout(surface)
                XCTAssertEqual(fixture.model.settings.toolbar, expected)
            }
        }
        fixture.model.settings.toolbar = all
        surface.reorderToolbarTool(.oneHand, before: .clipboard)
        XCTAssertEqual(fixture.model.settings.toolbar, [.language, .oneHand, .clipboard, .emoji, .appearance],
                       "The legacy insertion method keeps its documented before-target meaning")
    }
    func testGapDropUsesScrolledContentCoordinatesAndDragEndDoesNotRemoveTheTool() throws {
        let fixture = try Fixture(width: 180); defer { fixture.close() }
        let surface = fixture.surface; surface.showToolbarEditor(); layout(surface)
        let scroll = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "toolbar.shortcuts" } as? UIScrollView)
        scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width; layout(surface)
        let source = try button(.clipboard, in: surface), target = try button(.appearance, in: surface)
        XCTAssertTrue(surface.beginToolbarDrag(.clipboard))
        // The point lies in the final gap, closer to Appearance. Its coordinate
        // must include the scroll offset rather than treating the viewport as x=0.
        let point = target.convert(CGPoint(x: -2, y: target.bounds.midY), to: surface)
        surface.performToolbarDrop(.clipboard, at: point)
        let expected: [ToolbarTool] = [.language, .appearance, .emoji, .oneHand, .clipboard]
        XCTAssertEqual(fixture.model.settings.toolbar, expected)
        surface.finishToolbarDrag()
        source.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.model.settings.toolbar, expected, "A drag-end touch-up is not an editing remove tap")
        let current = try button(.clipboard, in: surface)
        current.sendActions(for: .touchDown); current.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.model.settings.toolbar, [.language, .appearance, .emoji, .oneHand])
    }
    func testDragAndLiftCancelPreviewsContainOnlyTransparentArtwork() throws {
        let fixture = try Fixture(width: 393); defer { fixture.close() }
        let surface = fixture.surface; surface.showToolbarEditor(); layout(surface)
        let button = try button(.clipboard, in: surface)
        XCTAssertTrue(views(button).compactMap { $0 as? UILabel }.contains { $0.text == "−" })
        let preview = surface.toolbarDragPreview(for: .clipboard)
        let imageView = try XCTUnwrap(preview.view as? UIImageView)
        XCTAssertTrue(imageView.subviews.isEmpty, "The edit badge and UIButton background cannot enter the drag image")
        XCTAssertFalse(imageView.isOpaque); XCTAssertEqual(imageView.backgroundColor?.cgColor.alpha, 0)
        XCTAssertEqual(preview.parameters.backgroundColor.cgColor.alpha, 0)
        XCTAssertTrue(preview.parameters.shadowPath?.isEmpty == true)
        let targeted = try XCTUnwrap(surface.toolbarTargetedPreview(for: .clipboard))
        XCTAssertTrue(targeted.view is UIImageView); XCTAssertTrue(targeted.target.container === surface)
        XCTAssertEqual(targeted.parameters.backgroundColor.cgColor.alpha, 0)
        let bitmap = try XCTUnwrap(imageView.image?.cgImage)
        var rgba = [UInt8](repeating: 0, count: 4)
        let pixel = try XCTUnwrap(bitmap.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        try rgba.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertEqual(rgba[3], 0, "The icon corner must be transparent rather than a black drag tile")
        let attachment = XCTAttachment(image: try XCTUnwrap(imageView.image)); attachment.name = "Toolbar-transparent-drag-artwork"
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testHeightSliderCommitsRoundedDeduplicatedValuesAndSupportsAccessibilityChanges() throws {
        let fixture = try Fixture(width: 393); defer { fixture.close() }
        let surface = fixture.surface
        fixture.model.settings.hand = .left; layout(surface)
        let resize = try XCTUnwrap(views(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "onehand.resize" })
        resize.sendActions(for: .touchUpInside); layout(surface)
        let slider = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "keyboard.heightSlider" } as? UISlider)
        XCTAssertFalse(slider.isContinuous)
        var heightChanges = 0; surface.onHeightChange = { _ in heightChanges += 1 }
        slider.value = 50.2; slider.sendActions(for: .valueChanged)
        XCTAssertEqual(heightChanges, 0)
        slider.value = 51.8; slider.sendActions(for: .valueChanged)
        XCTAssertEqual(fixture.model.settings.keyHeight, 52); XCTAssertEqual(slider.value, 52)
        slider.value = 52.2; slider.sendActions(for: .valueChanged)
        XCTAssertEqual(heightChanges, 1, "Repeated values in the same rounded step must not resize the remote keyboard")
    }
    func testCompatibilityModeIsIdleOnlyAndLocalPreeditSharesTheUncompressedHeader() async throws {
        let fixture = try Fixture(width: 180); defer { fixture.close() }
        let surface = fixture.surface
        let brand = try XCTUnwrap(views(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "toolbar.tools" })
        brand.sendActions(for: .touchUpInside); layout(surface)
        let toggle = try XCTUnwrap(views(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "keyboard.compatibleInput" })
        XCTAssertTrue(toggle.configuration?.title?.contains("自动") == true)
        toggle.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.model.settings.localPinyinComposition, true)
        XCTAssertEqual(fixture.model.settings.toolbar, all, "Compatibility is not a fifth pinnable toolbar tool")
        surface.closePanel(); layout(surface)
        fixture.document.usesLocalPinyinComposition = true
        let keys = views(surface).compactMap { $0 as? KeyButton }
        let frames = keys.map { $0.convert($0.bounds, to: surface) }, height = surface.desiredHeight
        try await waitFor { fixture.model.engineState == "离线就绪" }
        for letter in "nihao" { fixture.model.handle(.text(String(letter))) }
        try await waitFor { fixture.model.candidatesAreCurrent && !fixture.model.candidates.isEmpty }
        let preedit = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "keyboard.localPreedit" } as? UILabel)
        let candidates = try XCTUnwrap(views(surface).compactMap { $0 as? CandidateScrollView }.first)
        XCTAssertFalse(preedit.isHidden); XCTAssertEqual(preedit.text, "nihao")
        XCTAssertEqual(preedit.font.pointSize, 12); XCTAssertEqual(preedit.lineBreakMode, .byTruncatingMiddle)
        XCTAssertGreaterThan(preedit.bounds.width, 0); XCTAssertLessThanOrEqual(preedit.bounds.width, 100)
        XCTAssertEqual(preedit.bounds.height, 44); XCTAssertEqual(candidates.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(candidates.frame.minX, preedit.frame.maxX + 8)
        XCTAssertGreaterThanOrEqual(candidates.bounds.width, 44)
        XCTAssertEqual(keys.map { $0.convert($0.bounds, to: surface) }, frames)
        XCTAssertEqual(surface.desiredHeight, height)
        XCTAssertEqual(fixture.document.contextBefore, "", "This fixture never inserts provisional pinyin into its host")
        surface.toggleLocalPinyinComposition()
        XCTAssertEqual(fixture.model.settings.localPinyinComposition, true, "An active composition cannot switch transports")
        fixture.model.clearComposition()
        XCTAssertTrue(preedit.isHidden)
        fixture.document.usesLocalPinyinComposition = false
        for letter in "nihao" { fixture.model.handle(.text(String(letter))) }
        XCTAssertTrue(preedit.isHidden)
        XCTAssertEqual(candidates.frame.minX, 12, accuracy: 0.5, "A normal host retains the original candidate-row origin")
        XCTAssertEqual(candidates.bounds.height, 44)
        XCTAssertEqual(keys.map { $0.convert($0.bounds, to: surface) }, frames)
    }
}
