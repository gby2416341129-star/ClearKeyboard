import UIKit
import ImageIO
import SwiftUI

@MainActor final class KeyboardSurface: UIView, UIDragInteractionDelegate, UIDropInteractionDelegate {
    let model: KeyboardModel
    let systemBacked: Bool
    var onHeightChange: ((CGFloat) -> Void)?
    var configureGlobe: ((UIButton) -> Void)? { didSet { layoutSignature = ""; render() } }
    private let toolbar = UIStackView()
    private let toolbarScroll = UIScrollView()
    private let toolbarShortcuts = UIStackView()
    private var toolbarWidth: NSLayoutConstraint?
    private var toolbarDragActive = false
    private var toolbarRebuildPending = false
    private var toolbarTapBlockedUntil: CFTimeInterval = 0
    private let candidateScroll = CandidateScrollView()
    private let localPreedit = UILabel()
    private let hint = UILabel()
    private let keyGlassGroup = UIView()
    private let characterButton = UIButton(type: .system)
    private let clipboardSuggestion = UIStackView()
    private let clipboardGlass = LiquidGlassView(radius: 18, clear: true)
    private let clipboardPaste = UIButton(type: .system)
    private var recentClip: Clip?
    private var dismissedClip: UUID?
    private var appearanceHost: UIHostingController<KeyboardAppearancePanel>?
    private var appearanceBridge: AppearanceBridge?
    private var keysContainer: UIView { keyGlassGroup }
    private var movingCursor = false
    private let sideRail = UIStackView()
    private var keys: [(KeyButton, Int, Double, Double)] = []
    private var layoutSignature = ""
    private var appearanceSignature = ""
    private var toolbarSignature = ""
    private var railMode: HandMode?
    private let deleteHint = UILabel()
    private var panel: UIView?
    private var observerTokens: [NSObjectProtocol] = []
    private var panelKind: ToolbarTool?
    private var toolboxVisible = false
    private var toolbarEditing = false
    private var initialized = false
    private var rendering = false
    private var renderQueued = false
    private var reportedHeight: CGFloat?
    private struct KeyPresentation: Equatable {
        let uppercase: Bool; let chinese: Bool; let shifted: Bool; let capsLocked: Bool; let enter: String
    }
    private var keyPresentation: KeyPresentation?
    private struct GeometryPresentation: Equatable {
        let size: CGSize; let keyHeight: Double; let hand: HandMode
        let fraction: Double; let left: CGFloat; let right: CGFloat
    }
    private var geometryPresentation: GeometryPresentation?
    private var keyFramesNeedLayout = true
    private var presentedHeaderHeight: CGFloat = -1
    private var requestedSpelling = ""
    private struct KeyContact {
        let key: ObjectIdentifier
        let action: KeyAction
        var released: Bool?
    }
    private var keyContacts: [KeyContact] = []
    var isInteractingWithCandidates: Bool { candidateScroll.holdsCandidateUpdates }
    private var candidateHeight: CGFloat { movingCursor || !model.composition.isEmpty || !model.candidates.isEmpty || model.arithmetic != nil ? 44 : 0 }
    private var headerHeight: CGFloat { KeyboardGeometry.headerHeight }
    private var metrics: KeyboardGeometry.Metrics { KeyboardGeometry.Metrics(keyHeight: model.settings.keyHeight) }
    var desiredHeight: CGFloat { metrics.contentHeight }

    init(model: KeyboardModel, systemBacked: Bool = false) {
        self.model = model; self.systemBacked = systemBacked
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear; clipsToBounds = !systemBacked
        layer.cornerCurve = .continuous; layer.cornerRadius = systemBacked ? 0 : 28
        // Remote hosts may advertise a much larger corner radius; never inherit it.
        if #available(iOS 26.0, *) { cornerConfiguration = .corners(radius: .fixed(systemBacked ? 0 : 28)) }
        toolbar.axis = .horizontal; toolbar.distribution = .fill; toolbar.alignment = .center; toolbar.spacing = 10
        addSubview(toolbar)
        toolbarScroll.accessibilityIdentifier = "toolbar.shortcuts"
        toolbarScroll.showsHorizontalScrollIndicator = false; toolbarScroll.showsVerticalScrollIndicator = false
        toolbarScroll.delaysContentTouches = false; toolbarScroll.canCancelContentTouches = true
        toolbarScroll.contentInsetAdjustmentBehavior = .never
        toolbarScroll.addInteraction(UIDropInteraction(delegate: self))
        toolbarShortcuts.axis = .horizontal; toolbarShortcuts.alignment = .center; toolbarShortcuts.spacing = 10
        toolbarShortcuts.translatesAutoresizingMaskIntoConstraints = false
        toolbarScroll.addSubview(toolbarShortcuts)
        NSLayoutConstraint.activate([
            toolbarShortcuts.leadingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.leadingAnchor),
            toolbarShortcuts.trailingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.trailingAnchor),
            toolbarShortcuts.topAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.topAnchor),
            toolbarShortcuts.bottomAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.bottomAnchor),
            toolbarShortcuts.heightAnchor.constraint(equalTo: toolbarScroll.frameLayoutGuide.heightAnchor),
            toolbarScroll.heightAnchor.constraint(equalToConstant: 38),
            toolbarScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        toolbarWidth = toolbarScroll.widthAnchor.constraint(equalToConstant: 0)
        toolbarWidth?.priority = .defaultHigh; toolbarWidth?.isActive = true
        addSubview(candidateScroll)
        localPreedit.font = .systemFont(ofSize: 12); localPreedit.textColor = .secondaryLabel
        localPreedit.numberOfLines = 1; localPreedit.lineBreakMode = .byTruncatingMiddle
        localPreedit.accessibilityIdentifier = "keyboard.localPreedit"; localPreedit.isHidden = true
        addSubview(localPreedit)
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.delaysContentTouches = false; candidateScroll.canCancelContentTouches = true
        candidateScroll.onInteractionChanged = { [weak model] active in model?.candidateInteractionChanged(active) }
        candidateScroll.onLoadMore = { [weak model] context in model?.loadMoreCandidates(context: context) }
        candidateScroll.onSelect = { [weak model] candidate, context, arithmetic in
            if arithmetic { model?.chooseArithmetic(candidate.text) }
            else { model?.chooseDisplayed(candidate, context: context) }
        }
        addSubview(hint); hint.font = .systemFont(ofSize: 13); hint.textColor = .secondaryLabel
        hint.textAlignment = .center; hint.isUserInteractionEnabled = false
        addSubview(keyGlassGroup); addSubview(sideRail)
        characterButton.setTitle("字", for: .normal)
        characterButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        characterButton.backgroundColor = .secondarySystemFill; characterButton.layer.cornerRadius = 10
        characterButton.accessibilityIdentifier = "candidate.characterMode"
        characterButton.addAction(UIAction { [weak self] _ in self?.model.toggleCharacterSelection() }, for: .touchUpInside)
        addSubview(characterButton)
        configureClipboardSuggestion(); addSubview(clipboardSuggestion)
        sideRail.axis = .vertical; sideRail.distribution = .fillEqually; sideRail.spacing = 6
        addSubview(deleteHint); deleteHint.isHidden = true; deleteHint.isUserInteractionEnabled = false
        deleteHint.font = .systemFont(ofSize: 13, weight: .semibold); deleteHint.textAlignment = .center
        deleteHint.textColor = .white; deleteHint.layer.cornerRadius = 10; deleteHint.clipsToBounds = true
        model.onChange = { [weak self] in
            guard let self else { return }
            self.compositionChanged()
            self.render()
        }
        // A result belongs to the collection, not to the whole remote keyboard's
        // layout. Native scrolling and key geometry need no layout invalidation.
        model.onCandidatesChange = { [weak self] in self?.renderCandidates() }
        model.onInputChange = { [weak self] in
            guard let self else { return }
            self.compositionChanged(); self.renderInput()
        }
        for name in [UIAccessibility.reduceTransparencyStatusDidChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observerTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.appearanceSignature = ""; self?.render() }
            })
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: KeyboardSurface, _: UITraitCollection) in
            view.appearanceSignature = ""; view.render()
        }
        initialized = true; render()
        model.clipboardCapture.onCapture = { [weak self] in
            guard let self else { return }
            self.reloadClipboardSuggestion()
            if self.panelKind == .clipboard { (self.panel as? ClipboardPanel)?.reloadFromDisk() }
        }
        reloadClipboardSuggestion(fresh: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { observerTokens.forEach { NotificationCenter.default.removeObserver($0) } }

    private func compositionChanged() {
        let raw = model.composition.raw
        guard requestedSpelling != raw || requestedLiteralRevision != model.literalInputRevision ||
              requestedCharacterMode != model.characterSelectionMode else { return }
        if (requestedLiteralRevision != model.literalInputRevision || (requestedSpelling != raw && !raw.isEmpty)),
           let clip = recentClip {
            dismissedClip = clip.id; recentClip = nil
        }
        requestedSpelling = raw
        requestedLiteralRevision = model.literalInputRevision
        requestedCharacterMode = model.characterSelectionMode
        // Letters use the lightweight input callback as well. Leaving that
        // path out kept the old row coasting and deferred new words until its
        // momentum ended, even though the new candidate query had completed.
        candidateScroll.inputChanged()
    }
    private var requestedLiteralRevision = 0
    private var requestedCharacterMode = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard initialized, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let settings = model.settings
        let geometry = GeometryPresentation(size: bounds.size, keyHeight: settings.keyHeight, hand: settings.hand,
            fraction: settings.oneHandFraction, left: safeAreaInsets.left, right: safeAreaInsets.right)
        let layout = KeyboardGeometry.layout(size: bounds.size, metrics: metrics, hand: settings.hand,
            oneHandFraction: settings.oneHandFraction, leadingInset: safeAreaInsets.left,
            trailingInset: safeAreaInsets.right, fitHeight: !systemBacked)
        if keyFramesNeedLayout || geometryPresentation != geometry {
            geometryPresentation = geometry; keyFramesNeedLayout = false
            toolbar.frame = layout.header
            keyGlassGroup.frame = layout.keys
            for (button, row, start, units) in keys {
                button.frame = CGRect(x: CGFloat(start) * layout.unitWidth, y: CGFloat(row) * layout.rowPitch,
                                      width: CGFloat(units) * layout.unitWidth, height: layout.rowPitch)
            }
            sideRail.isHidden = settings.hand == .full
            sideRail.frame = layout.sideRail
        }
        layoutCandidateHeader()
        renderCandidates()
        if panelKind == .clipboard {
            panel?.frame = CGRect(x: layout.panel.minX, y: 0, width: layout.panel.width, height: layout.panel.maxY)
        } else { panel?.frame = layout.panel }
    }
    func render() {
        guard initialized else { return }
        guard !rendering else {
            if !renderQueued {
                renderQueued = true
                DispatchQueue.main.async { [weak self] in self?.renderQueued = false; self?.render() }
            }
            return
        }
        rendering = true; defer { rendering = false }
        let settings = model.settings
        let uppercase = settings.language == .chinese || model.shifted
        let signature = "\(model.page)-\(settings.language)-\(model.document?.needsGlobe ?? true)"
        if signature != layoutSignature && !movingCursor {
            layoutSignature = signature
            keys.forEach { $0.0.removeFromSuperview() }; keys = []
            for (rowIndex, row) in KeyboardLayout.rows(page: model.page, uppercase: uppercase, globe: model.document?.needsGlobe ?? true, language: settings.language).enumerated() {
                var start = row.insetUnits
                for key in row.keys {
                    let button = KeyButton(key: key)
                    button.onInteractionChanged = { [weak self, weak button] active in
                        guard let self else { return }
                        self.model.document?.keyInteractionChanged(active)
                        if !active {
                            if let button { self.finishContact(button, released: false) }
                            self.model.cancelPreparation()
                        }
                    }
                    button.onPrepare = { [weak self, weak button] action in
                        guard let self, let button else { return }
                        if case .text = action { self.beginContact(button, action: action) }
                        else if action == .space || action == .enter { self.beginContact(button, action: action) }
                        self.model.prepare(action)
                    }
                    if key.action == .globe, let configureGlobe { configureGlobe(button) }
                    else { button.onAction = { [weak self, weak button] action in
                        guard let self else { return }
                        if let button, self.finishContact(button, released: true) { return }
                        self.model.handle(action)
                    } }
                    button.onCursor = { [weak model] translation in model?.trackCursor(translation: translation) }
                    button.onCursorBegan = { [weak self] in self?.model.beginCursorMovement(); self?.setCursorMode(true) }
                    button.onCursorEnded = { [weak self] in self?.model.endCursorMovement(); self?.setCursorMode(false) }
                    button.onDeleteHint = { [weak self, weak button] direction in self?.showDeleteHint(direction, near: button) }
                    button.onDeleteSwipe = { [weak self] clear in
                        guard let self else { return }
                        if clear { self.model.clearInput() }
                        else { _ = self.model.undoClearInput() }
                    }
                    keysContainer.addSubview(button); keys.append((button, rowIndex, start, key.units)); start += key.units
                }
            }
            appearanceSignature = ""; keyPresentation = nil; keyFramesNeedLayout = true
        }
        let toolSignature = "\(settings.toolbar)-\(toolbarEditing)-\(toolboxVisible)-\(panelKind?.rawValue ?? "")"
        if toolSignature != toolbarSignature { toolbarSignature = toolSignature; rebuildToolbar() }
        if railMode != settings.hand { railMode = settings.hand; rebuildRail() }
        let style = "\(settings.accent)-\(settings.customAccentHex ?? "")-\(settings.resolvedKeyGlassStrength)-\(settings.keyColorHex ?? "")-\(settings.candidateColorHex ?? "")-\(settings.usesVibration)-\(settings.resolvedVibrationIntensity)-\(traitCollection.userInterfaceStyle.rawValue)"
        let appearanceChanged = style != appearanceSignature
        if appearanceChanged {
            appearanceSignature = style; tintColor = settings.accentInkColor
        }
        let presentation = KeyPresentation(uppercase: uppercase, chinese: settings.language == .chinese,
            shifted: model.shifted, capsLocked: model.capsLocked,
            enter: model.composition.isEmpty ? (model.document?.enterTitle ?? "换行") : "确认")
        if appearanceChanged || keyPresentation != presentation {
            keyPresentation = presentation
            for (button, _, _, _) in keys {
                var title: String? = nil
                if case .text(let value) = button.key.action { title = uppercase && model.page == .letters ? value.uppercased() : value }
                if button.key.action == .space { title = settings.language == .chinese ? "空格" : "space" }
                if button.key.action == .language { title = settings.language == .chinese ? "中" : "EN" }
                if button.key.action == .enter { title = presentation.enter }
                if appearanceChanged { button.apply(settings, title: title, active: button.key.action == .shift && model.shifted, capsLocked: model.capsLocked) }
                else if let title { button.updateTitle(title) }
                button.updateShift(active: model.shifted, capsLocked: model.capsLocked)
                if button.key.action == .language {
                    button.accessibilityLabel = settings.language == .chinese ? "中文，点按切换英文" : "英文，点按切换中文"
                    button.accessibilityIdentifier = "key.language"
                }
            }
        }
        // Candidates and language changes share one header. Only a real height-setting
        // change should renegotiate the remote input view's size.
        if reportedHeight != desiredHeight { reportedHeight = desiredHeight; onHeightChange?(desiredHeight) }
        renderCandidates()
        if keyFramesNeedLayout || geometryPresentation?.keyHeight != settings.keyHeight ||
            geometryPresentation?.hand != settings.hand || geometryPresentation?.fraction != settings.oneHandFraction {
            setNeedsLayout()
        }
    }
    private func renderInput() {
        let raw = model.composition.raw
        if requestedSpelling != raw {
            requestedSpelling = raw; candidateScroll.inputChanged()
        }
        // A Chinese letter edit changes the row and, at most, the confirm key.
        // It does not rebuild style signatures or visit every key/glass layer.
        let title = raw.isEmpty ? (model.document?.enterTitle ?? "换行") : "确认"
        if let old = keyPresentation, old.enter != title {
            keyPresentation = KeyPresentation(uppercase: old.uppercase, chinese: old.chinese,
                shifted: old.shifted, capsLocked: old.capsLocked, enter: title)
            keys.first(where: { $0.0.key.action == .enter })?.0.updateTitle(title)
        }
        renderCandidates()
    }
    private func renderCandidates() {
        guard initialized else { return }
        let panelOpen = panel != nil
        let height = candidateHeight
        if presentedHeaderHeight != height {
            presentedHeaderHeight = height
            setNeedsLayout()
        }
        layoutCandidateHeader()
        let displayed = model.arithmetic?.candidates.map { Candidate(text: $0, consumed: 0) } ?? model.candidates
        // A result can arrive before the first host layout. Do not ask a zero-
        // sized flow layout to lay out 44-point cells; layout will pull the latest.
        if !panelOpen, height > 0, candidateScroll.bounds.width > 0 {
            candidateScroll.update(displayed, context: model.candidateContext, arithmetic: model.arithmetic != nil, accent: model.settings.accentInkColor, hasMore: model.hasMoreCandidates, textSize: model.settings.resolvedCandidateTextSize, textColor: model.settings.candidateTintColor)
        }
        let clipboardVisible = !panelOpen && !movingCursor && model.composition.isEmpty && model.arithmetic == nil && !model.hasEnglishPrefix && recentClip != nil
        model.englishSpaceSelectionIsVisible = !clipboardVisible && !panelOpen
        clipboardSuggestion.isHidden = !clipboardVisible
        toolbar.isHidden = clipboardVisible || panelKind == .clipboard || (!panelOpen && candidateHeight > 0)
        candidateScroll.isHidden = clipboardVisible || panelOpen || movingCursor || candidateHeight == 0
        characterButton.isHidden = panelOpen || movingCursor || model.settings.language != .chinese || model.composition.isEmpty
        characterButton.setTitle(model.characterSelectionMode ? "词" : "字", for: .normal)
        characterButton.accessibilityLabel = model.characterSelectionMode ? "返回词组候选" : "按单字选词"
        if let bridge = appearanceBridge, bridge.settings != model.settings { bridge.settings = model.settings }
        hint.isHidden = panelOpen || !movingCursor; hint.text = movingCursor ? "滑动键盘，移动光标" : nil
        // Candidate updates only touch the header, never the keys or glass layers.
        // The collection lays out in UIKit's normal pass, never synchronously
        // from a key event or a decoder completion.
    }
    private func layoutCandidateHeader() {
        // This is the same 44pt row in both transports. Input-only callbacks
        // update it directly; no host context getter or key layout is required.
        let base = toolbar.frame
        guard base.width > 0 else { return }
        var header = base.insetBy(dx: -4, dy: 0); header.size.height = candidateHeight
        characterButton.frame = CGRect(x: header.maxX - 37, y: header.minY + 6, width: 34, height: 32)
        let topFaces = keys.compactMap { entry -> CGRect? in
            let (button, row, _, _) = entry
            guard row == 0 else { return nil }
            let face = KeyboardGeometry.keyPlate(in: button.bounds, action: button.key.action, units: button.key.units)
            return button.convert(face, to: self)
        }
        let span = topFaces.reduce(CGRect.null) { $0.union($1) }
        clipboardSuggestion.frame = span.isNull ? base : CGRect(x: span.minX, y: base.minY, width: span.width, height: base.height)
        if model.settings.language == .chinese, !model.composition.isEmpty {
            header.size.width = max(0, header.width - 41)
        }
        let showsLocal = panel == nil && !movingCursor && model.settings.language == .chinese &&
            !model.composition.isEmpty && model.document?.usesLocalPinyinComposition == true
        let width = showsLocal ? min(100, max(0, header.width - 52)) : 0
        localPreedit.isHidden = width <= 0
        localPreedit.text = showsLocal ? model.composition.raw : nil
        localPreedit.frame = CGRect(x: header.minX, y: header.minY, width: width, height: KeyboardGeometry.headerHeight)
        if width > 0 { header.origin.x += width + 8; header.size.width -= width + 8 }
        if candidateScroll.frame != header { candidateScroll.frame = header }
        hint.frame = header
    }
    private func beginContact(_ button: KeyButton, action: KeyAction) {
        let key = ObjectIdentifier(button)
        guard !keyContacts.contains(where: { $0.key == key && $0.released == nil }) else { return }
        keyContacts.append(KeyContact(key: key, action: action, released: nil))
    }
    @discardableResult private func finishContact(_ button: KeyButton, released: Bool) -> Bool {
        let key = ObjectIdentifier(button)
        guard let index = keyContacts.firstIndex(where: { $0.key == key && $0.released == nil }) else { return false }
        keyContacts[index].released = released
        // With overlapping fingers, the second finger may lift first. Preserve
        // contact order without committing a key that slides away or is cancelled.
        while let first = keyContacts.first, let committed = first.released {
            keyContacts.removeFirst()
            if committed { model.handle(first.action) }
        }
        return true
    }
    private func circleButton(symbol: String? = nil, image: UIImage? = nil, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        let navigationIcon = symbol == "chevron.down" || symbol == "checkmark"
        if #available(iOS 26.0, *), navigationIcon { config = .glass() }
        if let image { config.image = image }
        else if let symbol, navigationIcon {
            config.image = ToolArtwork.image(symbol: symbol, size: 24)
        }
        config.baseForegroundColor = .secondaryLabel
        if #unavailable(iOS 26.0) { config.background.backgroundColor = navigationIcon ? .secondarySystemFill : .clear }
        config.background.cornerRadius = navigationIcon ? 17 : 0
        config.contentInsets = .zero
        button.configuration = config; button.accessibilityLabel = label
        if let symbol, !navigationIcon, image == nil {
            let icon = ToolIconView(symbol: symbol); icon.translatesAutoresizingMaskIntoConstraints = false; button.addSubview(icon)
            NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: button.centerXAnchor),icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),icon.widthAnchor.constraint(equalToConstant: 28),icon.heightAnchor.constraint(equalToConstant: 28)])
        }
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    private func rebuildToolbar() {
        // A settings save renders synchronously. Keep the source and all drop
        // targets alive until UIKit finishes the drag and its cancel animation.
        guard !toolbarDragActive else { toolbarRebuildPending = true; return }
        let offset = toolbarScroll.contentOffset
        toolbar.removeArrangedSubview(toolbarScroll); toolbarScroll.removeFromSuperview()
        toolbar.arrangedSubviews.forEach { toolbar.removeArrangedSubview($0); $0.removeFromSuperview() }
        toolbarShortcuts.arrangedSubviews.forEach { toolbarShortcuts.removeArrangedSubview($0); $0.removeFromSuperview() }
        let panelOpen = panel != nil
        let brand = circleButton(symbol: toolbarEditing ? "checkmark" : (panelOpen ? "chevron.down" : nil),
            image: panelOpen ? nil : ToolArtwork.brand(size: 28),
            label: toolbarEditing ? "完成工具栏编辑" : (panelOpen ? "返回键盘" : "键盘工具")) { [weak self] in
                guard let self else { return }
                if self.panel != nil { self.closePanel() }
                else { self.showToolbox() }
            }
        brand.configuration?.baseForegroundColor = panelOpen ? .secondaryLabel : model.settings.accentInkColor
        brand.accessibilityIdentifier = "toolbar.tools"
        toolbar.addArrangedSubview(brand)
        let spacer = UIView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        toolbar.addArrangedSubview(spacer)
        let tools = model.settings.toolbar.filter { $0 != .language }
        for tool in tools {
            let button = circleButton(symbol: tool.symbol, label: tool.title) { [weak self] in
                guard let self, !self.toolbarDragActive, CACurrentMediaTime() >= self.toolbarTapBlockedUntil else { return }
                if self.toolbarEditing { self.setToolPinned(tool, pinned: false) }
                else { self.activateTool(tool) }
            }
            button.addAction(UIAction { [weak self] _ in
                guard let self, !self.toolbarDragActive else { return }
                self.toolbarTapBlockedUntil = 0
            }, for: .touchDown)
            button.accessibilityIdentifier = "toolbar.\(tool.rawValue)"
            let drag = UIDragInteraction(delegate: self); drag.isEnabled = true; button.addInteraction(drag)
            button.addInteraction(UIDropInteraction(delegate: self))
            if !toolbarEditing {
                let edit = UILongPressGestureRecognizer(target: self, action: #selector(editToolbar(_:)))
                edit.minimumPressDuration = 0.6; button.addGestureRecognizer(edit)
            }
            if toolbarEditing {
                let badge = UILabel(frame: CGRect(x: 24, y: -2, width: 13, height: 13))
                badge.text = "−"; badge.textAlignment = .center; badge.font = .systemFont(ofSize: 12, weight: .bold)
                badge.backgroundColor = .secondaryLabel; badge.textColor = .systemBackground
                badge.layer.cornerRadius = 6.5; badge.clipsToBounds = true; button.addSubview(badge)
                button.accessibilityLabel = "移除" + tool.title + "，拖动可排序"
            }
            toolbarShortcuts.addArrangedSubview(button)
        }
        toolbarWidth?.constant = CGFloat(tools.count * 34 + max(0, tools.count - 1) * 10)
        toolbar.addArrangedSubview(toolbarScroll)
        toolbarScroll.setContentOffset(offset, animated: false)
        setNeedsLayout()
    }
    @objc private func editToolbar(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began && !toolbarEditing { showToolbarEditor() } }
    func setToolPinned(_ tool: ToolbarTool, pinned: Bool) {
        guard tool != .language else { return }
        var tools = model.settings.toolbar
        if pinned {
            guard !tools.contains(tool) else { return }
            tools.append(tool)
        } else { tools.removeAll { $0 == tool } }
        model.settings.toolbar = tools
        if toolbarEditing { showToolbarEditor() }
    }
    func reorderToolbarTool(_ tool: ToolbarTool, before target: ToolbarTool) {
        var tools = model.settings.toolbar
        guard tool != .language, target != .language, tool != target, let from = tools.firstIndex(of: tool), tools.contains(target) else { return }
        tools.remove(at: from)
        guard let to = tools.firstIndex(of: target) else { return }
        tools.insert(tool, at: to)
        model.settings.toolbar = tools
    }
    func exchangeToolbarTool(_ tool: ToolbarTool, with target: ToolbarTool) {
        var tools = model.settings.toolbar
        guard tool != .language, target != .language, tool != target,
              let from = tools.firstIndex(of: tool), let to = tools.firstIndex(of: target) else { return }
        tools.swapAt(from, to); model.settings.toolbar = tools
    }
    @discardableResult func beginToolbarDrag(_ tool: ToolbarTool) -> Bool {
        guard toolbarEditing, tool != .language, model.settings.toolbar.contains(tool) else { return false }
        toolbarDragActive = true; toolbarTapBlockedUntil = .infinity
        return true
    }
    func finishToolbarDrag() {
        guard toolbarDragActive else { return }
        toolbarDragActive = false; toolbarTapBlockedUntil = CACurrentMediaTime() + 0.25
        if toolbarRebuildPending { toolbarRebuildPending = false; toolbarSignature = ""; render() }
    }
    private func toolbarButton(_ tool: ToolbarTool) -> UIButton? {
        toolbarShortcuts.arrangedSubviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "toolbar.\(tool.rawValue)" }
    }
    private func toolbarPreviewView(_ tool: ToolbarTool) -> UIImageView {
        let view = UIImageView(image: ToolArtwork.image(symbol: tool.symbol, size: 28, style: traitCollection.userInterfaceStyle))
        view.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        view.backgroundColor = .clear; view.isOpaque = false; view.contentMode = .scaleAspectFit
        return view
    }
    private func toolbarPreviewParameters() -> UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters(); parameters.backgroundColor = .clear
        parameters.shadowPath = UIBezierPath()
        return parameters
    }
    func toolbarDragPreview(for tool: ToolbarTool) -> UIDragPreview {
        UIDragPreview(view: toolbarPreviewView(tool), parameters: toolbarPreviewParameters())
    }
    func toolbarTargetedPreview(for tool: ToolbarTool) -> UITargetedDragPreview? {
        guard window != nil, let button = toolbarButton(tool) else { return nil }
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
        return UITargetedDragPreview(view: toolbarPreviewView(tool), parameters: toolbarPreviewParameters(),
                                    target: UIDragPreviewTarget(container: self, center: center))
    }
    func performToolbarDrop(_ tool: ToolbarTool, at point: CGPoint) {
        guard toolbarEditing,
              toolbarScroll.convert(toolbarScroll.bounds, to: self).insetBy(dx: -4, dy: -5).contains(point) else { return }
        let location = toolbarShortcuts.convert(point, from: self)
        let buttons = toolbarShortcuts.arrangedSubviews.compactMap { $0 as? UIButton }
        guard let closest = buttons.min(by: { abs($0.frame.midX - location.x) < abs($1.frame.midX - location.x) }),
              let identifier = closest.accessibilityIdentifier,
              let target = ToolbarTool(rawValue: String(identifier.dropFirst("toolbar.".count))) else { return }
        exchangeToolbarTool(tool, with: target)
    }
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard toolbarEditing, let identifier = interaction.view?.accessibilityIdentifier,
              let tool = ToolbarTool(rawValue: identifier.replacingOccurrences(of: "toolbar.", with: "")),
              beginToolbarDrag(tool) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: tool.rawValue as NSString)); item.localObject = tool
        item.previewProvider = { [weak self] in self?.toolbarDragPreview(for: tool) }
        return [item]
    }
    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
        (item.localObject as? ToolbarTool).flatMap { toolbarTargetedPreview(for: $0) }
    }
    func dragInteraction(_ interaction: UIDragInteraction, previewForCancelling item: UIDragItem, withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? {
        (item.localObject as? ToolbarTool).flatMap { toolbarTargetedPreview(for: $0) }
    }
    func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) { finishToolbarDrag() }
    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool { toolbarEditing && session.localDragSession != nil }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal { UIDropProposal(operation: toolbarEditing ? .move : .cancel) }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard session.localDragSession != nil, let tool = session.items.first?.localObject as? ToolbarTool else { return }
        performToolbarDrop(tool, at: session.location(in: self))
    }
    private func rebuildRail() {
        sideRail.arrangedSubviews.forEach { sideRail.removeArrangedSubview($0); $0.removeFromSuperview() }
        let opposite: HandMode = model.settings.hand == .right ? .left : .right
        let actions: [(String, String, String, () -> Void)] = [
            (opposite == .left ? "左手模式" : "右手模式", opposite == .left ? "arrow.left" : "arrow.right", "onehand.switch", { [weak self] in self?.model.settings.hand = opposite }),
            ("键盘调整", "arrow.up.and.down", "onehand.resize", { [weak self] in self?.showPanel(.oneHand) }),
            ("全尺寸", "arrow.up.left.and.arrow.down.right", "onehand.full", { [weak self] in self?.model.settings.hand = .full })
        ]
        for (title, symbol, identifier, action) in actions {
            var config = UIButton.Configuration.plain(); config.title = title; config.image = ToolArtwork.image(symbol: symbol, size: 26)
            config.imagePlacement = .top; config.imagePadding = 6; config.baseForegroundColor = .secondaryLabel
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in var result = values; result.font = .systemFont(ofSize: 10); return result }
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            button.accessibilityIdentifier = identifier; sideRail.addArrangedSubview(button)
        }
    }
    private func setCursorMode(_ active: Bool) {
        movingCursor = active; toolbar.isUserInteractionEnabled = !active; sideRail.isUserInteractionEnabled = !active
        keys.forEach { $0.0.setCursorMode(active) }; render()
    }
    private func showDeleteHint(_ direction: Int?, near button: KeyButton?) {
        guard let direction, let button else { deleteHint.isHidden = true; return }
        let key = button.convert(button.bounds, to: self)
        deleteHint.frame = CGRect(x: max(8, min(bounds.width - 154, key.maxX - 146)), y: max(2, key.minY - 38), width: 146, height: 34)
        deleteHint.text = direction > 0 ? "↑ 松手清空" : direction < 0 ? "↓ 松手撤回" : "↑ 清空  ·  ↓ 撤回"
        deleteHint.backgroundColor = direction < 0 ? .systemTeal : direction > 0 ? .systemRed : .darkGray
        deleteHint.isHidden = false; bringSubviewToFront(deleteHint)
    }
    func closePanel() {
        appearanceHost?.willMove(toParent: nil)
        panel?.removeFromSuperview(); panel = nil; panelKind = nil; toolboxVisible = false; toolbarEditing = false
        appearanceHost?.removeFromParent()
        appearanceHost = nil; appearanceBridge = nil
        keyGlassGroup.isHidden = false; render()
    }
    private func activateTool(_ tool: ToolbarTool) {
        if tool == .oneHand {
            closePanel()
            model.settings.hand = model.settings.hand == .right ? .left : .right
        } else if tool == .language { closePanel(); model.toggleLanguage() }
        else { showPanel(tool) }
    }
    func stopInteractions() { keys.forEach { $0.0.stopTracking() }; KeyboardVibration.shared.stop(); finishToolbarDrag(); setCursorMode(false); closePanel() }
    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
    private func configureClipboardSuggestion() {
        clipboardSuggestion.axis = .horizontal; clipboardSuggestion.spacing = 4; clipboardSuggestion.alignment = .fill
        clipboardSuggestion.accessibilityIdentifier = "clipboard.recent"
        clipboardSuggestion.isLayoutMarginsRelativeArrangement = true
        clipboardSuggestion.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        clipboardGlass.translatesAutoresizingMaskIntoConstraints = false
        clipboardGlass.accessibilityIdentifier = "clipboard.recent.material"
        clipboardSuggestion.insertSubview(clipboardGlass, at: 0)
        NSLayoutConstraint.activate([
            clipboardGlass.leadingAnchor.constraint(equalTo: clipboardSuggestion.leadingAnchor),
            clipboardGlass.trailingAnchor.constraint(equalTo: clipboardSuggestion.trailingAnchor),
            clipboardGlass.topAnchor.constraint(equalTo: clipboardSuggestion.topAnchor, constant: 2),
            clipboardGlass.bottomAnchor.constraint(equalTo: clipboardSuggestion.bottomAnchor, constant: -2)
        ])
        var config = UIButton.Configuration.plain()
        config.image = ToolArtwork.image(symbol: "doc.on.clipboard.fill", size: 24, style: traitCollection.userInterfaceStyle)
        config.imagePadding = 10; config.contentInsets = .zero; config.baseForegroundColor = .label
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in
            var next = values; next.font = .systemFont(ofSize: 15, weight: .medium); return next
        }
        clipboardPaste.configuration = config; clipboardPaste.contentHorizontalAlignment = .leading
        clipboardPaste.accessibilityIdentifier = "clipboard.recent.paste"
        clipboardPaste.setContentHuggingPriority(.defaultLow, for: .horizontal)
        clipboardPaste.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clipboardPaste.addAction(UIAction { [weak self] _ in self?.pasteRecentClip() }, for: .touchUpInside)
        clipboardSuggestion.addArrangedSubview(clipboardPaste)
        let expand = UIButton(type: .system)
        expand.setImage(ToolArtwork.image(symbol: "chevron.down", size: 24), for: .normal)
        expand.tintColor = .label; expand.accessibilityLabel = "打开剪贴板历史"
        expand.accessibilityIdentifier = "clipboard.recent.history"
        expand.widthAnchor.constraint(equalToConstant: 36).isActive = true
        expand.addAction(UIAction { [weak self] _ in self?.showPanel(.clipboard) }, for: .touchUpInside)
        clipboardSuggestion.addArrangedSubview(expand)
        let close = UIButton(type: .system)
        close.setImage(ToolArtwork.image(symbol: "xmark", size: 22), for: .normal)
        close.tintColor = .label; close.accessibilityLabel = "关闭本次剪贴提示"
        close.accessibilityIdentifier = "clipboard.recent.close"
        close.widthAnchor.constraint(equalToConstant: 36).isActive = true
        close.addAction(UIAction { [weak self] _ in self?.dismissRecentClip() }, for: .touchUpInside)
        clipboardSuggestion.addArrangedSubview(close)
    }
    private func reloadClipboardSuggestion(fresh: Bool = true) {
        let store = ClipboardStore(url: SharedStorage.clipboardURL(allowShared: model.document?.fullAccess == true))
        store.prune(lifetime: model.settings.clipboardLifetimeHours * 3600)
        if fresh { dismissedClip = nil }
        recentClip = store.clips.first.flatMap {
            $0.id != dismissedClip && (fresh || Date().timeIntervalSince($0.createdAt) < 900) ? $0 : nil
        }
        clipboardPaste.configuration?.title = recentClip?.text.replacingOccurrences(of: "\n", with: " ")
        clipboardPaste.accessibilityLabel = recentClip.map { "粘贴：" + $0.text }
        renderCandidates()
    }
    private func dismissRecentClip() {
        if let id = recentClip?.id { dismissedClip = id }
        recentClip = nil; renderCandidates()
    }
    private func pasteRecentClip() {
        guard let clip = recentClip else { return }
        if let attachment = clip.attachment {
            let store = ClipboardStore(url: SharedStorage.clipboardURL(allowShared: model.document?.fullAccess == true))
            guard let data = store.attachmentData(for: clip) else { dismissRecentClip(); return }
            UIPasteboard.general.setItems([[attachment.typeIdentifier: data]], options: [.localOnly: true])
            UIAccessibility.post(notification: .announcement, argument: "已复制，请在输入框粘贴")
        } else { model.insertLiteral(clip.text) }
        dismissRecentClip()
    }
    private func panelStack(title: String) -> UIStackView {
        let container = UIView(); container.backgroundColor = .clear
        container.accessibilityLabel = title
        container.accessibilityContainerType = .semanticGroup
        addSubview(container); panel = container; keyGlassGroup.isHidden = true
        let scroll = KeyboardPanelScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(scroll)
        scroll.accessibilityIdentifier = "keyboard.panelScroll"
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor), scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24)])
        return stack
    }
    private func showToolbox() {
        closePanel(); toolboxVisible = true
        let stack = panelStack(title: "键盘工具")
        let items: [(String, String, () -> Void)] = ToolbarTool.allCases.map { tool in
            (tool == .language ? "中 / EN" : tool.title, tool.symbol, { [weak self] in
                self?.activateTool(tool)
            })
        } + [("定制工具栏", "rectangle.3.group.fill", { [weak self] in self?.showToolbarEditor() }),
             (compatibilityInputTitle, "desktopcomputer", { [weak self] in self?.toggleLocalPinyinComposition() })]
        buildGrid(items, in: stack, identifiers: [compatibilityInputTitle: "keyboard.compatibleInput"]); render()
    }
    private var compatibilityInputTitle: String {
        model.settings.localPinyinComposition == true ? "兼容输入 · 开" : "兼容输入 · 关"
    }
    func toggleLocalPinyinComposition() {
        guard model.composition.isEmpty else { return }
        model.settings.localPinyinComposition = model.settings.localPinyinComposition == true ? nil : true
        showToolbox()
    }
    func showToolbarEditor() {
        closePanel(); toolbarEditing = true; toolboxVisible = true
        let stack = panelStack(title: "定制工具栏")
        let items: [(String, String, () -> Void)] = ToolbarTool.allCases.filter { $0 != .language }.map { tool in
            let selected = model.settings.toolbar.contains(tool)
            return ((selected ? "− " : "+ ") + tool.title, tool.symbol, { [weak self] in self?.setToolPinned(tool, pinned: !selected) })
        }
        buildGrid(items, in: stack); render()
    }
    private func buildGrid(_ items: [(String, String, () -> Void)], in stack: UIStackView, identifiers: [String: String] = [:]) {
        for start in stride(from: 0, to: items.count, by: 3) {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 8; row.distribution = .fillEqually
            for offset in 0..<3 {
                guard start + offset < items.count else { row.addArrangedSubview(UIView()); continue }
                let (title, symbol, action) = items[start + offset]
                let button = ToolTileButton(title: title, symbol: symbol, action: action)
                button.accessibilityIdentifier = identifiers[title]
                button.heightAnchor.constraint(equalToConstant: 60).isActive = true; row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
        }
    }
    private func showPanel(_ kind: ToolbarTool) {
        if panelKind == kind { closePanel(); return }
        closePanel(); panelKind = kind
        if kind == .clipboard {
            let content = ClipboardPanel(model: model)
            content.onClose = { [weak self] in self?.closePanel() }
            addSubview(content); panel = content; keyGlassGroup.isHidden = true; render(); return
        }
        if kind == .appearance {
            let bridge = AppearanceBridge(settings: model.settings) { [weak model] value in model?.settings = value }
            let host = UIHostingController(rootView: KeyboardAppearancePanel(bridge: bridge))
            // Remote keyboard hosts must receive drags that begin between rows.
            host.view.backgroundColor = UIColor(white: 0.5, alpha: 0.01); host.view.isOpaque = false
            appearanceBridge = bridge; appearanceHost = host
            var responder: UIResponder? = self
            while let current = responder {
                if let owner = current as? UIViewController { owner.addChild(host); break }
                responder = current.next
            }
            addSubview(host.view)
            if let owner = host.parent { host.didMove(toParent: owner) }
            panel = host.view; keyGlassGroup.isHidden = true; render(); setNeedsLayout(); return
        }
        let stack = panelStack(title: kind.title)
        switch kind {
        case .clipboard: break
        case .emoji: buildEmoji(stack)
        case .language: model.toggleLanguage(); closePanel()
        case .oneHand:
            let segment = UISegmentedControl(items: HandMode.allCases.map(\.title))
            segment.selectedSegmentIndex = HandMode.allCases.firstIndex(of: model.settings.hand) ?? 0
            segment.addAction(UIAction { [weak self, weak segment] _ in
                guard let self, let segment else { return }; self.model.settings.hand = HandMode.allCases[segment.selectedSegmentIndex]
            }, for: .valueChanged); stack.addArrangedSubview(segment)
            stack.addArrangedSubview(note("键盘宽度"))
            let width = UISlider(); width.isContinuous = false; width.minimumValue = 0.68; width.maximumValue = 0.88; width.value = Float(model.settings.oneHandFraction)
            width.accessibilityLabel = "单手键盘宽度"
            width.addAction(UIAction { [weak self, weak width] _ in if let width { self?.model.settings.oneHandWidth = Double(width.value) } }, for: .valueChanged)
            stack.addArrangedSubview(width)
            stack.addArrangedSubview(note("按键高度"))
            let height = UISlider(); height.minimumValue = 44; height.maximumValue = 58; height.value = Float(model.settings.keyHeight)
            height.accessibilityLabel = "按键高度"; height.accessibilityIdentifier = "keyboard.heightSlider"; height.isContinuous = false
            height.addAction(UIAction { [weak self, weak height] _ in
                guard let self, let height else { return }
                let value = Double(height.value.rounded()); height.value = Float(value)
                guard self.model.settings.keyHeight != value else { return }
                self.model.settings.keyHeight = value
            }, for: .valueChanged)
            stack.addArrangedSubview(height)
        case .appearance: break
        }
        render(); setNeedsLayout()
    }
    private func actionButton(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        if let symbol { button.setImage(ToolArtwork.image(symbol: symbol, size: 24), for: .normal) }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside); return button
    }
    private func note(_ text: String) -> UILabel {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabel; return label
    }
    private func buildEmoji(_ stack: UIStackView) {
        let groups = [["😀", "🥹", "🥰", "😎", "🥳", "😭", "🤔", "🫶"], ["👍", "🙏", "❤️", "✨", "🎉", "🌙", "☕️", "🌸"], ["(๑•̀ㅂ•́)و✧", "٩(ˊᗜˋ*)و", "(｡･ω･｡)", "晚安 🌙"]]
        for group in groups {
            let row = UIStackView(); row.axis = .horizontal; row.distribution = .fillEqually
            for emoji in group {
                let button = actionButton(emoji) { [weak self] in self?.model.insertLiteral(emoji) }
                button.titleLabel?.font = .systemFont(ofSize: emoji.count == 1 ? 26 : 11)
                row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
        }
        let stickers = UIStackView(); stickers.axis = .horizontal; stickers.distribution = .fillEqually
        for (title, emoji) in [("收到啦", "🫡"), ("好耶", "🎉"), ("谢谢", "🫶"), ("晚安", "🌙")] {
            stickers.addArrangedSubview(actionButton(title) { [weak self] in self?.copySticker(title, emoji: emoji) })
        }
        stack.addArrangedSubview(stickers)
    }
    private func copySticker(_ title: String, emoji: String) {
        guard model.document?.fullAccess == true else {
            announce("图片贴纸需要完全访问；文字表情可直接输入。")
            return
        }
        let color = model.settings.accentColor
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { context in
            let rect = CGRect(x: 8, y: 8, width: 284, height: 284)
            color.withAlphaComponent(0.16).setFill(); UIBezierPath(roundedRect: rect, cornerRadius: 64).fill()
            (emoji as NSString).draw(in: CGRect(x: 70, y: 30, width: 180, height: 160), withAttributes: [.font: UIFont.systemFont(ofSize: 120)])
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (title as NSString).draw(in: CGRect(x: 20, y: 208, width: 260, height: 68), withAttributes: [.font: UIFont.systemFont(ofSize: 42, weight: .semibold), .foregroundColor: model.settings.accentInkColor, .paragraphStyle: paragraph])
            _ = context
        }
        if let data = image.pngData() { UIPasteboard.general.setItems([["public.png": data]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]) }
        announce("贴纸已复制，请在消息框粘贴")
    }
}
