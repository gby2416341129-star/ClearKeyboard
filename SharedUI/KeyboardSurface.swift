import UIKit
import ImageIO
import SwiftUI

@MainActor final class KeyboardSurface: UIView, UIScrollViewDelegate {
    let model: KeyboardModel
    let systemBacked: Bool
    var onHeightChange: ((CGFloat) -> Void)?
    var configureGlobe: ((UIButton) -> Void)? { didSet { layoutSignature = ""; render() } }
    private let toolbar = UIStackView()
    private let toolbarScroll = ToolbarScrollView()
    private let toolbarShortcuts = UIStackView()
    private var toolbarWidth: NSLayoutConstraint?
    private var toolbarLeading: NSLayoutConstraint?
    private var toolbarButtons: [ToolbarTool: FeedbackButton] = [:]
    private var toolbarInstances: [(tool: ToolbarTool, button: FeedbackButton, copy: Int)] = []
    private var toolbarRenderedTools: [ToolbarTool] = []
    private var toolbarMiddleCopy = 0
    private let toolbarEffects = ToolbarTapEffects()
    private var toolbarBrand: UIButton?
    private let selectionDone = FeedbackButton(type: .system)
    private var toolbarNavigationState = ""
    private var editorTiles: [ToolbarTool: ToolTileButton] = [:]
    private var activeTool: ToolbarTool?
    private var toolbarOffset = CGFloat(UserDefaults.standard.double(forKey: "clear.toolbar.offset.v1"))
    private var draggedTool: ToolbarTool?
    private var dragIcon: UIImageView?
    private var dragPoint = CGPoint.zero
    private var toolbarDragUpdates: UIUpdateLink?
    private var toolbarDragOrder: [ToolbarTool]?
    private var toolbarDragSlots: [CGPoint] = []
    private var toolbarReorderAnimations: [ObjectIdentifier: UIViewPropertyAnimator] = [:]
    private var toolbarDragTimestamp: CFTimeInterval = 0
    private var toolbarDragGeneration = 0
    private var appearancePanelCache: KeyboardAppearancePanelView?
    private let clipboardText = ClipboardInlinePreview()
    private var toolbarDragActive = false
    private var toolbarTapBlockedUntil: CFTimeInterval = 0
    private let candidateScroll = CandidateScrollView()
    private var candidateActions: CandidateActionsOverlay?
    private let localPreedit = UILabel()
    private let hint = UILabel()
    private let keyGlassGroup = UIView()
    private let characterButton = UIButton(type: .system)
    private let clipboardSuggestion = UIStackView()
    private let clipboardGlass = LiquidGlassView(radius: 18, clear: true)
    private let clipboardPaste = UIButton(type: .system)
    private var recentClip: Clip?
    private let clipboardSuggestionState: ClipboardSuggestionState
    private var nativeAppearance: KeyboardAppearancePanelView?
    private var keysContainer: UIView { keyGlassGroup }
    private var movingCursor = false
    private let sideRail = UIStackView()
    private var keys: [(KeyButton, Int, Double, Double)] = []
    private var layoutSignature = ""
    private var appearanceSignature = ""
    private var toolbarSignature = ""
    private var railMode: HandMode?
    private let deleteHint = UILabel()
    private var noticeWork: DispatchWorkItem?
    private var panel: UIView?
    private let panelTransition = KeyboardPanelTransition()
    private let toolbarVibration: KeyboardVibration
    private var observerTokens: [NSObjectProtocol] = []
    private var panelKind: ToolbarTool?
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
    private var clipboardRevisionCache: (value: Int, sampledAt: TimeInterval)?
    private struct KeyContact {
        let key: ObjectIdentifier
        var action: KeyAction
        var released: Bool?
    }
    private var keyContacts: [KeyContact] = []
    var isInteractingWithCandidates: Bool { candidateScroll.holdsCandidateUpdates || (panel as? ClipboardPanel)?.isChoosing == true }
    private var candidateHeight: CGFloat { movingCursor || !model.composition.isEmpty || !model.candidates.isEmpty || model.arithmetic != nil ? 44 : 0 }
    private var headerHeight: CGFloat { KeyboardGeometry.headerHeight }
    private var metrics: KeyboardGeometry.Metrics { KeyboardGeometry.Metrics(keyHeight: model.settings.keyHeight) }
    var desiredHeight: CGFloat { metrics.contentHeight }

    init(model: KeyboardModel, systemBacked: Bool = false, toolbarVibration: KeyboardVibration? = nil, suggestionState: ClipboardSuggestionState? = nil) {
        self.model = model; self.systemBacked = systemBacked
        clipboardSuggestionState = suggestionState ?? ClipboardSuggestionState(defaults: SharedStorage.defaults(allowShared: model.document?.fullAccess == true))
        self.toolbarVibration = toolbarVibration ?? .shared
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = systemBacked ? .clear : UIColor(white: 0.5, alpha: 0.01); clipsToBounds = !systemBacked
        layer.cornerCurve = .continuous; layer.cornerRadius = systemBacked ? 0 : 28
        // Remote hosts may advertise a much larger corner radius; never inherit it.
        if #available(iOS 26.0, *) { cornerConfiguration = .corners(radius: .fixed(systemBacked ? 0 : 28)) }
        toolbar.axis = .horizontal; toolbar.distribution = .fill; toolbar.alignment = .center; toolbar.spacing = 10
        addSubview(toolbar)
        toolbarScroll.accessibilityIdentifier = "toolbar.shortcuts"
        toolbarScroll.showsHorizontalScrollIndicator = false; toolbarScroll.showsVerticalScrollIndicator = false
        toolbarScroll.delaysContentTouches = false; toolbarScroll.canCancelContentTouches = true
        toolbarScroll.delegate = self; toolbarScroll.alwaysBounceHorizontal = true
        toolbarScroll.pendingOffset = toolbarOffset
        toolbarScroll.onTooth = { [weak self] speed in
            guard let self, !self.toolbarDragActive, self.model.settings.usesToolbarScrollVibration else { return }
            self.toolbarVibration.attach(to: self); self.toolbarVibration.pulseScroll(speed: speed)
        }
        toolbarScroll.backgroundColor = .clear
        toolbarScroll.contentInsetAdjustmentBehavior = .never
        toolbarShortcuts.axis = .horizontal; toolbarShortcuts.alignment = .center; toolbarShortcuts.spacing = 10
        toolbarShortcuts.translatesAutoresizingMaskIntoConstraints = false
        toolbarScroll.addSubview(toolbarShortcuts)
        let leading = toolbarShortcuts.leadingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.leadingAnchor, constant: 4)
        toolbarLeading = leading
        NSLayoutConstraint.activate([
            leading,
            toolbarShortcuts.trailingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.trailingAnchor, constant: -7),
            toolbarShortcuts.topAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.topAnchor),
            toolbarShortcuts.bottomAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.bottomAnchor),
            toolbarShortcuts.heightAnchor.constraint(equalTo: toolbarScroll.frameLayoutGuide.heightAnchor),
            toolbarScroll.heightAnchor.constraint(equalToConstant: 38),
            toolbarScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        toolbarWidth = toolbarScroll.widthAnchor.constraint(equalToConstant: 0)
        toolbarWidth?.priority = .defaultHigh; toolbarWidth?.isActive = true
        selectionDone.setTitle("完成", for: .normal)
        selectionDone.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        selectionDone.accessibilityIdentifier = "clipboard.insertSelection"
        selectionDone.isHidden = true
        let completionWidth = selectionDone.widthAnchor.constraint(equalToConstant: 44)
        completionWidth.priority = .init(999); completionWidth.isActive = true
        selectionDone.heightAnchor.constraint(equalToConstant: 34).isActive = true
        selectionDone.addAction(UIAction { [weak self] _ in
            self?.toolbarPulse(); (self?.panel as? ClipboardPanel)?.finishSelection()
        }, for: .touchUpInside)
        candidateScroll.onManage = { [weak self] candidate, context, rect in
            self?.showCandidateActions(candidate, context: context, rect: rect)
        }
        addSubview(candidateScroll)
        localPreedit.font = .systemFont(ofSize: 12); localPreedit.textColor = .secondaryLabel
        localPreedit.numberOfLines = 1; localPreedit.lineBreakMode = .byTruncatingMiddle
        localPreedit.accessibilityIdentifier = "keyboard.localPreedit"; localPreedit.isHidden = true
        addSubview(localPreedit)
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.delaysContentTouches = false; candidateScroll.canCancelContentTouches = true
        candidateScroll.onInteractionChanged = { [weak model] active in model?.candidateInteractionChanged(active) }
        candidateScroll.onLoadMore = { [weak model] context in model?.loadMoreCandidates(context: context) }
        model.onCandidateSelection = { [weak self] in
            guard let self, self.model.settings.usesCandidateVibration else { return }
            self.toolbarVibration.attach(to: self); self.toolbarVibration.pulseInterface()
        }
        candidateScroll.onSelect = { [weak model] candidate, context, arithmetic in
            if arithmetic { model?.chooseArithmetic(candidate.text) }
            else { model?.chooseDisplayed(candidate, context: context) }
        }
        addSubview(hint); hint.font = .systemFont(ofSize: 13); hint.textColor = .secondaryLabel
        hint.textAlignment = .center; hint.isUserInteractionEnabled = false
        addSubview(keyGlassGroup); addSubview(sideRail)
        characterButton.setTitle("字", for: .normal)
        characterButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        characterButton.titleLabel?.transform = CGAffineTransform(translationX: 0, y: -1)
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
        model.onContentKey = { [weak self] in self?.consumeClipboardForTyping() }
        model.onNotice = nil
        model.clipboardCapture.onFailure = nil
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
            if self.panelKind == .clipboard || self.panelKind == .phrases { (self.panel as? ClipboardPanel)?.reloadFromDisk() }
        }
        reloadClipboardSuggestion(fresh: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { observerTokens.forEach { NotificationCenter.default.removeObserver($0) } }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { KeyboardVibration.shared.attach(to: self) }
        else { stopInteractions(preservePanel: true) }
    }
    private func compositionChanged() {
        let raw = model.composition.raw
        guard requestedSpelling != raw || requestedLiteralRevision != model.literalInputRevision ||
              requestedCharacterMode != model.characterSelectionMode else { return }
        if (requestedLiteralRevision != model.literalInputRevision || (requestedSpelling != raw && !raw.isEmpty)),
           let clip = recentClip {
            clipboardSuggestionState.consume(clip, revision: clipboardRevision()); recentClip = nil
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
        let fullHeader = KeyboardGeometry.layout(size: bounds.size, metrics: metrics, hand: .full,
            oneHandFraction: settings.oneHandFraction, leadingInset: safeAreaInsets.left,
            trailingInset: safeAreaInsets.right, fitHeight: !systemBacked).header
        let layout = KeyboardGeometry.layout(size: bounds.size, metrics: metrics, hand: settings.hand,
            oneHandFraction: settings.oneHandFraction, leadingInset: safeAreaInsets.left,
            trailingInset: safeAreaInsets.right, fitHeight: !systemBacked)
        if keyFramesNeedLayout || geometryPresentation != geometry {
            geometryPresentation = geometry; keyFramesNeedLayout = false
            UIView.performWithoutAnimation {
                toolbar.frame = fullHeader
                candidateHeaderFrame = layout.header
                keyGlassGroup.frame = layout.keys
                for (button, row, start, units) in keys {
                    button.frame = CGRect(x: CGFloat(start) * layout.unitWidth, y: CGFloat(row) * layout.rowPitch,
                                          width: CGFloat(units) * layout.unitWidth, height: layout.rowPitch)
                }
                sideRail.isHidden = settings.hand == .full
                sideRail.frame = layout.sideRail
            }
        }
        layoutCandidateHeader()
        var panelFrame = layout.panel
        panelFrame.size.height = max(0, bounds.height - panelFrame.minY)
        panel?.frame = panelFrame
        let contentWidth = CGFloat(toolbarInstances.count * 44 + 1)
        // The completion action shares the existing header. The words start
        // directly below it; no second empty header is reserved by the panel.
        let available = max(0, fullHeader.width - (selectionDone.isHidden ? 54 : 108))
        let width = available
        toolbarScroll.expectedContentWidth = max(contentWidth, width)
        toolbarLeading?.constant = 4
        if toolbarWidth?.constant != width { toolbarWidth?.constant = width }
        toolbar.layoutIfNeeded(); toolbarShortcuts.layoutIfNeeded()
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
                        switch action { case .text, .literal: self.consumeClipboardForTyping(); default: break }
                        // A Space selection has one selection pulse after commit,
                        // instead of also firing the ordinary typing pulse down.
                        button.suppressTypingVibration = action == .space && self.model.spaceSelectsCandidate
                        self.beginContact(button, action: action)
                        self.model.prepare(action)
                    }
                    if key.action == .globe, let configureGlobe { configureGlobe(button) }
                    else { button.onAction = { [weak self, weak button] action in
                        guard let self else { return }
                        if let button, self.finishContact(button, released: true, replacement: action) { return }
                        if let button, !self.keyContacts.isEmpty {
                            self.keyContacts.append(KeyContact(key: ObjectIdentifier(button), action: action, released: true)); return
                        }
                        self.model.handle(action)
                    } }
                    button.onAlternateBegan = { [weak model] in model?.cancelPreparation() }
                    button.onCursor = { [weak model] translation in model?.trackCursor(translation: translation) }
                    button.onCursorBegan = { [weak self] in self?.model.beginCursorMovement(); self?.setCursorMode(true) }
                    button.onCursorEnded = { [weak self] in self?.model.endCursorMovement(); self?.setCursorMode(false) }
                    button.onDeleteHint = { [weak self, weak button] direction in self?.showDeleteHint(direction, near: button) }
                    button.onDeleteSwipe = { [weak self] clear in
                        guard let self else { return }
                        self.keys.forEach { $0.0.stopTracking() }
                        if clear { self.model.clearInput() }
                        else { _ = self.model.undoClearInput() }
                    }
                    keysContainer.addSubview(button); keys.append((button, rowIndex, start, key.units)); start += key.units
                }
            }
            appearanceSignature = ""; keyPresentation = nil; keyFramesNeedLayout = true
        }
        let toolSignature = "\(settings.toolbar)-\(toolbarEditing)"
        if toolSignature != toolbarSignature { toolbarSignature = toolSignature; rebuildToolbar() }
        updateToolbarState()
        if panelKind == .oneHand, let panel {
            func update(_ view: UIView) {
                if let segment = view as? UISegmentedControl { segment.selectedSegmentIndex = HandMode.allCases.firstIndex(of: settings.hand) ?? 0 }
                if let slider = view as? UISlider, !slider.isTracking {
                    if slider.accessibilityLabel == "单手键盘宽度" { slider.value = Float(settings.oneHandFraction) }
                    if slider.accessibilityIdentifier == "keyboard.heightSlider" { slider.value = Float(settings.keyHeight) }
                }
                view.subviews.forEach(update)
            }
            update(panel)
        }
        if railMode != settings.hand { railMode = settings.hand; rebuildRail() }
        candidateScroll.selectionVibrationEnabled = settings.usesCandidateVibration
        (panel as? KeyboardHapticPanel)?.apply(settings)
        let style = "\(settings.usesToolbarTapVibration)-\(settings.usesLogoVibration)-\(settings.usesToolbarScrollVibration)-\(settings.usesCandidateVibration)-\(settings.accent)-\(settings.customAccentHex ?? "")-\(settings.resolvedKeyGlassStrength)-\(settings.keyColorHex ?? "")-\(settings.candidateColorHex ?? "")-\(settings.usesVibration)-\(settings.resolvedVibrationIntensity)-\(settings.resolvedVibrationMode)-\(traitCollection.userInterfaceStyle.rawValue)"
        let appearanceChanged = style != appearanceSignature
        if appearanceChanged {
            appearanceSignature = style; tintColor = settings.accentInkColor
            (panel as? KeyboardHapticPanel)?.apply(settings)
        }
        let presentation = KeyPresentation(uppercase: uppercase, chinese: settings.language == .chinese,
            shifted: model.shifted, capsLocked: model.capsLocked,
            enter: model.composition.isEmpty ? (model.document?.enterTitle ?? "换行") : "确认")
        if panel == nil && (appearanceChanged || keyPresentation != presentation) {
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
        if !panelOpen, height == 0, !candidateScroll.isHidden { candidateScroll.prepareToDisappear() }
        if presentedHeaderHeight != height {
            presentedHeaderHeight = height
            setNeedsLayout()
        }
        layoutCandidateHeader()
        let displayed = model.arithmetic?.candidates.map { Candidate(text: $0, consumed: 0) } ?? model.candidates
        // A result can arrive before the first host layout. Do not ask a zero-
        // sized flow layout to lay out 44-point cells; layout will pull the latest.
        if !panelOpen, height > 0, candidateScroll.bounds.width > 0 {
            candidateScroll.update(displayed, context: model.candidateContext, arithmetic: model.arithmetic != nil, accent: model.settings.accentInkColor, hasMore: model.hasMoreCandidates, textSize: model.settings.resolvedCandidateTextSize, textColor: model.settings.candidateTintColor, animation: model.settings.resolvedCandidateAnimation, awaitingResults: model.isAwaitingFirstCandidate)
        }
        let clipboardVisible = !panelOpen && !movingCursor && model.composition.isEmpty && model.arithmetic == nil && !model.hasEnglishPrefix && recentClip != nil
        model.englishSpaceSelectionIsVisible = !clipboardVisible && !panelOpen
        clipboardSuggestion.isHidden = !clipboardVisible
        toolbar.isHidden = clipboardVisible || (!panelOpen && candidateHeight > 0)
        candidateScroll.isHidden = clipboardVisible || panelOpen || movingCursor || candidateHeight == 0
        characterButton.isHidden = panelOpen || movingCursor || model.settings.language != .chinese || model.composition.isEmpty
        characterButton.setTitle(model.characterSelectionMode ? "词" : "字", for: .normal)
        characterButton.accessibilityLabel = model.characterSelectionMode ? "返回词组候选" : "按单字选词"
        if panelKind == .appearance { nativeAppearance?.apply(model.settings) }
        hint.isHidden = panelOpen || !movingCursor; hint.text = movingCursor ? "滑动键盘，移动光标" : nil
        // Candidate updates only touch the header, never the keys or glass layers.
        // The collection lays out in UIKit's normal pass, never synchronously
        // from a key event or a decoder completion.
    }
    private var candidateHeaderFrame = CGRect.zero
    private func layoutCandidateHeader() {
        // This is the same 44pt row in both transports. Input-only callbacks
        // update it directly; no host context getter or key layout is required.
        let base = candidateHeaderFrame
        guard base.width > 0 else { return }
        var header = base.insetBy(dx: -4, dy: 0); header.size.height = candidateHeight
        characterButton.frame = CGRect(x: header.maxX - 37, y: header.midY - 16, width: 34, height: 32)
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
        let spellingWidth = ceil((model.composition.raw as NSString).size(withAttributes: [.font: localPreedit.font!]).width) + 8
        let width = showsLocal ? min(max(26, spellingWidth), min(90, max(0, header.width * 0.26))) : 0
        localPreedit.isHidden = width <= 0
        localPreedit.text = showsLocal ? model.composition.raw : nil
        localPreedit.frame = CGRect(x: header.minX, y: header.minY, width: width, height: KeyboardGeometry.headerHeight)
        if width > 0 { header.origin.x += width + 8; header.size.width -= width + 8 }
        if candidateScroll.frame != header { candidateScroll.frame = header }
        hint.frame = header
    }
    private func showCandidateActions(_ candidate: Candidate, context: KeyboardModel.CandidateContext, rect: CGRect) {
        candidateActions?.close()
        let overlay = CandidateActionsOverlay(anchor: candidateScroll.convert(rect, to: self), in: self,
            pin: { [weak self] in self?.model.manageCandidate(candidate, context: context, pinned: true) },
            remove: { [weak self] in self?.model.manageCandidate(candidate, context: context, pinned: false) })
        overlay.onDismiss = { [weak self] in self?.candidateActions = nil; self?.candidateScroll.dismissManagement() }
        addSubview(overlay); candidateActions = overlay
    }
    private func beginContact(_ button: KeyButton, action: KeyAction) {
        let key = ObjectIdentifier(button)
        guard !keyContacts.contains(where: { $0.key == key && $0.released == nil }) else { return }
        keyContacts.append(KeyContact(key: key, action: action, released: nil))
    }
    @discardableResult private func finishContact(_ button: KeyButton, released: Bool, replacement: KeyAction? = nil) -> Bool {
        let key = ObjectIdentifier(button)
        guard let index = keyContacts.firstIndex(where: { $0.key == key && $0.released == nil }) else { return false }
        if let replacement { keyContacts[index].action = replacement }
        keyContacts[index].released = released
        // With overlapping fingers, the second finger may lift first. Preserve
        // contact order without committing a key that slides away or is cancelled.
        while let first = keyContacts.first, let committed = first.released {
            keyContacts.removeFirst()
            if committed { model.handle(first.action) }
        }
        return true
    }
    private func circleButton(symbol: String? = nil, image: UIImage? = nil, label: String, independentNavigation: Bool = false, shortcut: Bool = false, action: @escaping () -> Void) -> UIButton {
        let navigationIcon = symbol == "chevron.down" || symbol == "checkmark"
        let button = FeedbackButton(type: navigationIcon ? .system : .custom)
        var config = UIButton.Configuration.plain()
        if #available(iOS 26.0, *), navigationIcon { config = .glass() }
        if !navigationIcon {
            config.background = .clear()
            button.backgroundColor = .clear
            button.layer.borderWidth = 0; button.layer.shadowOpacity = 0
        }
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
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self else { return }
            if independentNavigation { self.prepareToolbarNavigation() }
            else {
                guard !self.toolbarDragActive, CACurrentMediaTime() >= self.toolbarTapBlockedUntil,
                      !self.toolbarScroll.isDragging else { return }
            }
            let feedbackEnabled = independentNavigation ? self.model.settings.usesLogoVibration : shortcut ? self.model.settings.usesToolbarTapVibration : true
            if feedbackEnabled { self.toolbarPulse() }
            button?.playActivationFeedback()
            if let button, button.accessibilityIdentifier?.hasPrefix("toolbar.") == true,
               !self.toolbarEditing, !self.toolbarDragActive, CACurrentMediaTime() >= self.toolbarTapBlockedUntil {
                self.toolbarEffects.play(from: button, in: self, neighbors: self.toolbarInstances.map(\.button), tint: self.model.settings.accentInkColor)
            }
            action()
        }, for: .touchUpInside)
        return button
    }
    private func rebuildToolbar() {
        if toolbarBrand == nil {
            let brand = circleButton(image: ToolArtwork.brand(size: 32), label: "键盘工具", independentNavigation: true) { [weak self] in
                guard let self else { return }
                if self.panel != nil { self.closePanel() } else { self.showToolbox() }
            }
            // Stop momentum at touch-down so the same touch can activate this
            // fixed sibling button; it is not a shortcut/scroll-stop gesture.
            brand.addAction(UIAction { [weak self] _ in self?.prepareToolbarNavigation() }, for: .touchDown)
            brand.accessibilityIdentifier = "toolbar.tools"; toolbarBrand = brand
            toolbar.addArrangedSubview(brand)
            let spacer = UIView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            toolbar.addArrangedSubview(spacer); toolbar.addArrangedSubview(toolbarScroll); toolbar.addArrangedSubview(selectionDone)
        }
        let tools = (toolbarDragOrder ?? model.settings.toolbar).filter { $0 != .language }
        guard tools != toolbarRenderedTools || toolbarInstances.isEmpty else { updateToolbarState(); return }
        toolbarRenderedTools = tools
        let originals = toolbarButtons
        toolbarShortcuts.arrangedSubviews.forEach { toolbarShortcuts.removeArrangedSubview($0); $0.removeFromSuperview() }
        toolbarButtons = [:]; toolbarInstances = []
        let period = CGFloat(tools.count) * 44
        let screen = window?.screen.bounds.size ?? UIScreen.main.bounds.size
        let visibleCycles = period > 0 ? Int(ceil(max(bounds.width, max(screen.width, screen.height)) / period)) : 0
        let copies = tools.isEmpty ? 1 : max(3, visibleCycles * 2 + 3)
        toolbarMiddleCopy = copies / 2
        func makeButton(_ tool: ToolbarTool) -> FeedbackButton {
            let button = circleButton(symbol: tool.symbol, label: tool.title, shortcut: true) { [weak self] in
                guard let self, !self.toolbarDragActive, CACurrentMediaTime() >= self.toolbarTapBlockedUntil else { return }
                if self.toolbarEditing { self.setToolPinned(tool, pinned: false) } else { self.activateTool(tool) }
            } as! FeedbackButton
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(toolbarHold(_:)))
            hold.minimumPressDuration = 0.35; button.addGestureRecognizer(hold)
            return button
        }
        for copy in 0..<copies {
            for tool in tools {
                let button = copy == toolbarMiddleCopy ? (originals[tool] ?? makeButton(tool)) : makeButton(tool)
                button.accessibilityIdentifier = "toolbar." + tool.rawValue + (copy == toolbarMiddleCopy ? "" : ".copy\(copy)")
                button.isAccessibilityElement = copy == toolbarMiddleCopy
                button.alpha = 1; button.transform = .identity
                toolbarShortcuts.addArrangedSubview(button); toolbarInstances.append((tool, button, copy))
                if copy == toolbarMiddleCopy { toolbarButtons[tool] = button }
            }
        }
        toolbarScroll.loopPeriod = period; toolbarScroll.loopCenter = CGFloat(toolbarMiddleCopy) * period
        toolbarScroll.pendingOffset = period > 0 ? toolbarScroll.loopCenter + toolbarOffset.truncatingRemainder(dividingBy: period) : 0
        toolbarScroll.edgeIcons = toolbarInstances.compactMap { $0.button.subviews.compactMap { $0 as? ToolIconView }.first }
        updateToolbarState(); setNeedsLayout()
    }
    private func updateToolbarState() {
        let selectionPanel = panel as? ClipboardPanel
        selectionDone.isHidden = selectionPanel?.isChoosing != true
        selectionDone.isEnabled = selectionPanel?.canFinishSelection == true
        let state = "\(toolbarEditing)-\(panel != nil)"
        if state != toolbarNavigationState, let brand = toolbarBrand {
            toolbarNavigationState = state
            var config = UIButton.Configuration.plain()
            config.contentInsets = .zero
            config.background = .clear()
            config.image = ToolArtwork.brand(size: 32)
            brand.configuration = config
            brand.accessibilityTraits = panel != nil ? [.button, .selected] : .button
            brand.accessibilityLabel = toolbarEditing ? "完成工具栏编辑" : panel != nil ? "返回键盘" : "键盘工具"
        }
        for (tool, button, _) in toolbarInstances {
            let badgeTag = 6301
            if toolbarEditing, button.viewWithTag(badgeTag) == nil {
                let badge = UILabel(frame: CGRect(x: 21, y: 0, width: 13, height: 13))
                badge.tag = badgeTag; badge.text = "−"; badge.textAlignment = .center
                badge.font = .systemFont(ofSize: 12, weight: .semibold)
                badge.backgroundColor = .tertiarySystemFill; badge.textColor = .label
                badge.layer.cornerRadius = 6.5; badge.clipsToBounds = true; badge.isUserInteractionEnabled = false
                button.addSubview(badge)
            } else if !toolbarEditing { button.viewWithTag(badgeTag)?.removeFromSuperview() }
            button.setEditingMotion(toolbarEditing && !toolbarDragActive)
            button.accessibilityLabel = toolbarEditing ? "移除" + tool.title + "，长按拖动排序" : tool.title
            let active = activeTool == tool || (tool == .appearance && panelKind == .appearance) ||
                (tool == .oneHand && model.settings.hand != .full) ||
                (tool == .compatibility && model.settings.localPinyinComposition == true)
            button.accessibilityTraits = active ? [.button, .selected] : .button
            button.subviews.compactMap { $0 as? ToolIconView }.first?.setActive(active && !toolbarEditing, tint: model.settings.accentInkColor)
            if tool == .oneHand, !toolbarEditing {
                let enabled = model.settings.hand != .full
                button.accessibilityLabel = enabled ? "单手模式，已开启，点按恢复全宽" : "单手模式，点按开启"
                button.accessibilityTraits = enabled ? [.button, .selected] : .button
            }
            if tool == .compatibility {
                let enabled = model.settings.localPinyinComposition == true
                button.subviews.compactMap { $0 as? ToolIconView }.first?.setCompatibilityEnabled(enabled)
                if !toolbarEditing {
                    button.accessibilityLabel = enabled ? "兼容输入，已开启" : "兼容输入，已关闭"
                    button.accessibilityTraits = enabled ? [.button, .selected] : .button
                }
            }
        }
        for (tool, tile) in editorTiles { tile.configureManagement(title: tool.title, pinned: model.settings.toolbar.contains(tool)) }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === toolbarScroll { toolbarScroll.updateScrollFeedback() }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView === toolbarScroll, !decelerate { rememberToolbarOffset() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { if scrollView === toolbarScroll { rememberToolbarOffset() } }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === toolbarScroll else { return }
        if !toolbarScroll.isLooping { targetContentOffset.pointee.x = toolbarScroll.clampedOffset(targetContentOffset.pointee.x) }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === toolbarScroll {
            toolbarScroll.pendingOffset = nil
            if model.settings.usesToolbarScrollVibration { toolbarVibration.attach(to: self); toolbarVibration.prepareScroll() }
        }
    }
    private func prepareToolbarNavigation() {
        guard toolbarDragActive || toolbarScroll.isDragging || toolbarScroll.isTracking ||
              toolbarScroll.isDecelerating || toolbarScroll.pendingOffset != nil else { return }
        if toolbarDragActive { finishToolbarDrag() }
        let offset = toolbarScroll.contentOffset, wasEnabled = toolbarScroll.isScrollEnabled
        let suppressed = toolbarScroll.suppressScrollFeedback
        toolbarScroll.pendingOffset = nil; toolbarScroll.suppressScrollFeedback = true
        // The Logo is outside this scroll view. Cancelling its pan/deceleration
        // leaves the Logo's own tracking intact and preserves the visible phase.
        toolbarScroll.isScrollEnabled = false
        toolbarScroll.setContentOffset(offset, animated: false)
        toolbarScroll.isScrollEnabled = wasEnabled
        rememberToolbarOffset()
        toolbarScroll.suppressScrollFeedback = suppressed
    }
    private func rememberToolbarOffset() {
        toolbarScroll.pendingOffset = nil
        toolbarOffset = toolbarScroll.isLooping ? toolbarScroll.phaseOffset : toolbarScroll.clampedOffset(toolbarScroll.contentOffset.x)
        UserDefaults.standard.set(Double(toolbarOffset), forKey: "clear.toolbar.offset.v1")
    }
    private func editorPulse() {
        toolbarPulse()
    }
    private func toolbarPulse() {
        toolbarVibration.attach(to: self)
        toolbarVibration.pulseInterface()
    }
    func setToolPinned(_ tool: ToolbarTool, pinned: Bool) {
        guard tool != .language else { return }
        var tools = model.settings.toolbar
        if pinned { guard !tools.contains(tool) else { return }; tools.append(tool) }
        else { guard tools.contains(tool) else { return }; tools.removeAll { $0 == tool } }
        model.settings.toolbar = tools
        render(); updateToolbarState()
    }
    func reorderToolbarTool(_ tool: ToolbarTool, before target: ToolbarTool) {
        var tools = model.settings.toolbar
        guard tool != .language, target != .language, tool != target, let from = tools.firstIndex(of: tool), tools.contains(target) else { return }
        tools.remove(at: from)
        guard let to = tools.firstIndex(of: target) else { return }
        tools.insert(tool, at: to); model.settings.toolbar = tools
    }
    func exchangeToolbarTool(_ tool: ToolbarTool, with target: ToolbarTool) {
        var tools = model.settings.toolbar
        guard tool != .language, target != .language, let from = tools.firstIndex(of: tool), let to = tools.firstIndex(of: target) else { return }
        tools.swapAt(from, to); model.settings.toolbar = tools
    }
    @discardableResult func beginToolbarDrag(_ tool: ToolbarTool) -> Bool {
        guard tool != .language, model.settings.toolbar.contains(tool) else { return false }
        if toolbarDragActive { finishToolbarDrag() }
        toolbarDragGeneration += 1; toolbarEffects.cancel()
        toolbarShortcuts.layoutIfNeeded()
        toolbarDragOrder = model.settings.toolbar
        toolbarDragSlots = model.settings.toolbar.filter { $0 != .language }.compactMap { toolbarButtons[$0]?.center }
        draggedTool = tool
        toolbarDragActive = true; toolbarTapBlockedUntil = .infinity; toolbarScroll.suppressScrollFeedback = true
        toolbarScroll.pendingOffset = nil
        toolbarScroll.setContentOffset(toolbarScroll.contentOffset, animated: false)
        updateToolbarState()
        return true
    }
    private func stopToolbarDragUpdates() {
        toolbarDragUpdates?.requiresContinuousUpdates = false
        toolbarDragUpdates?.isEnabled = false; toolbarDragUpdates = nil
        toolbarDragTimestamp = 0
    }
    func finishToolbarDrag() {
        let wasDragging = toolbarDragActive || draggedTool != nil
        stopToolbarDragUpdates()
        guard wasDragging else { return }
        toolbarDragGeneration += 1
        let order = toolbarDragOrder; toolbarDragOrder = nil
        if let tool = draggedTool { toolbarInstances.filter { $0.tool == tool }.forEach { $0.button.alpha = 1 } }
        dragIcon?.removeFromSuperview(); dragIcon = nil; draggedTool = nil
        toolbarDragActive = false; toolbarScroll.suppressScrollFeedback = false; toolbarTapBlockedUntil = CACurrentMediaTime() + 0.18
        // Keep the same arranged views throughout the drag. Commit their real
        // order and remove compensating transforms in one layout transaction.
        UIView.performWithoutAnimation {
            for animator in toolbarReorderAnimations.values where animator.state == .active {
                animator.stopAnimation(false); animator.finishAnimation(at: .end)
            }
            toolbarReorderAnimations.removeAll(); toolbarDragSlots.removeAll()
            toolbarInstances.forEach { $0.button.transform = .identity }
            if let order, order != model.settings.toolbar { model.settings.toolbar = order }
            toolbarSignature = ""; render()
            toolbar.layoutIfNeeded(); toolbarShortcuts.layoutIfNeeded()
        }
        toolbarScroll.refreshEdgeAppearance(); rememberToolbarOffset()
    }
    @objc private func toolbarHold(_ gesture: UILongPressGestureRecognizer) {
        guard let instance = toolbarInstances.first(where: { $0.button === gesture.view }) else { return }
        let tool = instance.tool
        dragPoint = gesture.location(in: self)
        switch gesture.state {
        case .began:
            if !toolbarEditing { showToolbarEditor() } else { editorPulse() }
            guard beginToolbarDrag(tool) else { return }
            let image = toolbarPreviewView(tool); image.center = dragPoint
            image.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            addSubview(image); dragIcon = image
            toolbarInstances.filter { $0.tool == tool }.forEach { $0.button.alpha = 0 }
            let updates = UIUpdateLink(view: self)
            updates.addAction(to: .beforeCATransactionCommit) { [weak self] _, _ in self?.toolbarDragTick() }
            let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
            updates.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            updates.requiresContinuousUpdates = true; updates.isEnabled = true
            toolbarDragTimestamp = CACurrentMediaTime(); toolbarDragUpdates = updates
        case .changed:
            // Follow the finger directly; reorder and edge scrolling run once
            // per display opportunity, not again for every touch sample.
            dragIcon?.center = dragPoint
        case .ended, .cancelled, .failed:
            toolbarDragTick(); stopToolbarDragUpdates()
            let generation = toolbarDragGeneration
            if let image = dragIcon, let button = nearestToolbarButton(tool, to: dragPoint.x), !UIAccessibility.isReduceMotionEnabled {
                let target = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
                UIView.animate(withDuration: 0.26, delay: 0, usingSpringWithDamping: 0.90, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState], animations: {
                    image.center = target; image.transform = .identity
                }, completion: { [weak self] _ in
                    guard let self, self.toolbarDragGeneration == generation else { return }
                    self.finishToolbarDrag()
                })
            } else { finishToolbarDrag() }
        default: break
        }
    }
    private func toolbarDragTick() {
        guard let tool = draggedTool, toolbarDragActive else { return }
        dragIcon?.center = dragPoint
        let now = CACurrentMediaTime()
        let elapsed = min(1.0 / 30, max(0, now - toolbarDragTimestamp))
        toolbarDragTimestamp = now
        let point = toolbarScroll.convert(dragPoint, from: self)
        guard abs(point.y - toolbarScroll.bounds.midY) < 42 else { return }
        let viewportX = point.x - toolbarScroll.contentOffset.x
        let edge: CGFloat = 30
        let left = max(0, min(1, (edge - viewportX) / edge))
        let right = max(0, min(1, (viewportX - (toolbarScroll.bounds.width - edge)) / edge))
        let movement = (right - left) * 210 * CGFloat(elapsed)
        if abs(movement) > 0.001 {
            let x = toolbarScroll.clampedOffset(toolbarScroll.contentOffset.x + movement)
            if abs(x - toolbarScroll.contentOffset.x) > 0.001 {
                toolbarOffset = x; toolbarScroll.contentOffset.x = x
            }
        }
        performToolbarDrop(tool, at: dragPoint)
        toolbarScroll.refreshEdgeAppearance()
    }
    private func presentToolbarDragOrder(_ tools: [ToolbarTool]) {
        let visible = tools.filter { $0 != .language }
        for (tool, button, copy) in toolbarInstances {
            guard let index = visible.firstIndex(of: tool), toolbarDragSlots.indices.contains(index) else { continue }
            let x = toolbarDragSlots[index].x + CGFloat(copy - toolbarMiddleCopy) * toolbarScroll.loopPeriod
            let target = CGAffineTransform(translationX: x - button.center.x, y: 0)
            guard button.transform != target else { continue }
            let key = ObjectIdentifier(button)
            if let animator = toolbarReorderAnimations[key], animator.state == .active {
                animator.stopAnimation(false); animator.finishAnimation(at: .current)
            }
            if UIAccessibility.isReduceMotionEnabled || tool == draggedTool { button.transform = target; continue }
            let animator = UIViewPropertyAnimator(duration: 0.24, dampingRatio: 0.90) { button.transform = target }
            toolbarReorderAnimations[key] = animator; animator.startAnimation()
        }
    }
    private func nearestToolbarButton(_ tool: ToolbarTool, to x: CGFloat) -> FeedbackButton? {
        toolbarInstances.filter { $0.tool == tool }.min {
            abs($0.button.convert(CGPoint(x: $0.button.bounds.midX, y: 0), to: self).x - x) <
            abs($1.button.convert(CGPoint(x: $1.button.bounds.midX, y: 0), to: self).x - x)
        }?.button
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
        guard toolbarScroll.convert(toolbarScroll.bounds, to: self).insetBy(dx: -4, dy: -5).contains(point) else { return }
        let location = toolbarShortcuts.convert(point, from: self)
        var tools = toolbarDragOrder ?? model.settings.toolbar
        let visible = tools.filter { $0 != .language }
        let from: Int, to: Int
        if toolbarDragActive {
            guard let source = visible.firstIndex(of: tool), toolbarDragSlots.indices.contains(source), !visible.isEmpty,
                  let nearest = toolbarInstances.enumerated().min(by: { abs($0.element.button.center.x - location.x) < abs($1.element.button.center.x - location.x) }) else { return }
            let slot = nearest.offset % visible.count
            guard slot != source, let sourceIndex = tools.firstIndex(of: tool), let targetIndex = tools.firstIndex(of: visible[slot]) else { return }
            let copy = nearest.element.copy
            let sourceX = toolbarDragSlots[source].x + CGFloat(copy - toolbarMiddleCopy) * toolbarScroll.loopPeriod
            let targetX = nearest.element.button.center.x
            let threshold = abs(targetX - sourceX) / 2 + 3
            guard abs(location.x - sourceX) > threshold else { return }
            from = sourceIndex; to = targetIndex
        } else {
            let buttons = toolbarShortcuts.arrangedSubviews.compactMap { $0 as? UIButton }
            guard let closest = buttons.min(by: { abs($0.frame.midX - location.x) < abs($1.frame.midX - location.x) }),
                  let identifier = closest.accessibilityIdentifier,
                  let target = ToolbarTool(rawValue: String(identifier.dropFirst("toolbar.".count))),
                  tool != target, let sourceIndex = tools.firstIndex(of: tool), let targetIndex = tools.firstIndex(of: target) else { return }
            from = sourceIndex; to = targetIndex
        }
        tools.remove(at: from); tools.insert(tool, at: min(to, tools.count))
        if toolbarDragActive {
            toolbarDragOrder = tools; presentToolbarDragOrder(tools)
        } else { model.settings.toolbar = tools }
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
            let button = FeedbackButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.toolbarPulse(); action() })
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
        deleteHint.textColor = .white
        deleteHint.backgroundColor = direction < 0 ? .systemTeal : direction > 0 ? .systemRed : .darkGray
        deleteHint.isHidden = false; bringSubviewToFront(deleteHint)
    }
    private func preparePanelTransition(animated: Bool = true) {
        candidateActions?.close()
        (panel as? ClipboardPanel)?.endSelection()
        let region = keyGlassGroup.frame.union(panel?.frame ?? keyGlassGroup.frame).intersection(bounds)
        panelTransition.begin(in: self, region: region, animated: animated)
        panel?.removeFromSuperview()
        panel = nil; panelKind = nil; activeTool = nil; toolbarEditing = false
        editorTiles = [:]; nativeAppearance = nil
    }
    func closePanel(animated: Bool = true) {
        guard panel != nil else { if !animated { panelTransition.cancel() }; return }
        preparePanelTransition(animated: animated)
        appearanceSignature = ""; keyPresentation = nil
        finishPanelTransition()
    }
    private func finishPanelTransition() {
        keyGlassGroup.isHidden = panel != nil
        render(); setNeedsLayout(); layoutIfNeeded()
        panelTransition.finish(to: panel ?? keyGlassGroup, in: self)
    }
    private func activateTool(_ tool: ToolbarTool) {
        if tool != .oneHand, activeTool == tool, panel != nil { closePanel(); return }
        if tool == .oneHand {
            closePanel()
            model.settings.hand = model.settings.hand == .full ? (model.settings.resolvedPreferredHand == .full ? .right : model.settings.resolvedPreferredHand) : .full
        } else if tool == .language { closePanel(); model.toggleLanguage() }
        else if tool == .compatibility { toggleLocalPinyinComposition() }
        else if let item = appearanceItem(for: tool) {
            showPanel(.appearance, detail: item)
            activeTool = tool; updateToolbarState()
        } else { showPanel(tool) }
    }
    private func appearanceItem(for tool: ToolbarTool) -> AppearanceItem? {
        switch tool {
        case .keyGlass: return .keyGlass
        case .keyColor: return .keyColor
        case .textColor: return .candidateColor
        case .textSize: return .candidateSize
        default: return nil
        }
    }
    func stopInteractions(preservePanel: Bool = false) { toolbarEffects.cancel(); rememberToolbarOffset(); keys.forEach { $0.0.stopTracking() }; KeyboardVibration.shared.stop(); finishToolbarDrag(); setCursorMode(false); if !preservePanel { candidateActions?.close(); closePanel(animated: false) }; panelTransition.cancel() }
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
        clipboardPaste.widthAnchor.constraint(equalToConstant: 26).isActive = true
        clipboardSuggestion.addArrangedSubview(clipboardPaste)
        clipboardText.onPaste = { [weak self] in self?.pasteRecentClip() }
        clipboardText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        clipboardText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clipboardSuggestion.addArrangedSubview(clipboardText)
        let expand = UIButton(type: .system)
        expand.setImage(ToolArtwork.image(symbol: "chevron.down", size: 24), for: .normal)
        expand.tintColor = .label; expand.accessibilityLabel = "展开复制内容滑动选词"
        expand.accessibilityIdentifier = "clipboard.recent.history"
        expand.widthAnchor.constraint(equalToConstant: 36).isActive = true
        expand.addAction(UIAction { [weak self] _ in self?.showRecentSelection() }, for: .touchUpInside)
        clipboardSuggestion.addArrangedSubview(expand)
        let close = UIButton(type: .system)
        close.setImage(ToolArtwork.image(symbol: "xmark", size: 17), for: .normal)
        close.tintColor = .label; close.accessibilityLabel = "关闭本次剪贴提示"
        close.accessibilityIdentifier = "clipboard.recent.close"
        close.widthAnchor.constraint(equalToConstant: 36).isActive = true
        close.addAction(UIAction { [weak self] _ in self?.dismissRecentClip() }, for: .touchUpInside)
        clipboardSuggestion.addArrangedSubview(close)
    }
    private func reloadClipboardSuggestion(fresh: Bool = true) {
        clipboardRevisionCache = nil
        let revision = clipboardRevision()
        let store = ClipboardStore(url: SharedStorage.clipboardURL(allowShared: model.document?.fullAccess == true))
        let lifetime = model.settings.clipboardLifetimeHours * 3600, now = Date()
        recentClip = store.clips.first(where: { lifetime <= 0 || $0.pinned || now.timeIntervalSince($0.createdAt) <= lifetime }).flatMap {
            !clipboardSuggestionState.isConsumed($0, revision: revision) &&
                (fresh || Date().timeIntervalSince($0.createdAt) < 900) ? $0 : nil
        }
        clipboardPaste.configuration?.title = nil
        clipboardText.show(recentClip?.text ?? "")
        clipboardPaste.accessibilityLabel = recentClip.map { "粘贴：" + $0.text }
        renderCandidates()
    }
    private func showRecentSelection() {
        guard let clip = recentClip, clip.attachment == nil else { showPanel(.clipboard); return }
        let text = clip.text
        clipboardSuggestionState.consume(clip, revision: UIPasteboard.general.changeCount); recentClip = nil
        showPanel(.clipboard)
        (panel as? ClipboardPanel)?.selectText(text)
    }
    private func clipboardRevision() -> Int {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = clipboardRevisionCache, now - cached.sampledAt < 0.25 { return cached.value }
        let revision = UIPasteboard.general.changeCount
        clipboardRevisionCache = (revision, now)
        return revision
    }
    private func dismissRecentClip(revision: Int? = nil) {
        guard let clip = recentClip else { return }
        clipboardSuggestionState.consume(clip, revision: revision ?? clipboardRevision())
        recentClip = nil; renderCandidates()
    }
    private func consumeClipboardForTyping() {
        let revision = clipboardRevision()
        clipboardSuggestionState.consumeInputRevision(revision)
        dismissRecentClip(revision: revision)
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
        preparePanelTransition()
        let stack = panelStack(title: "键盘工具")
        let items: [(String, String, () -> Void)] = ToolbarTool.allCases.map { tool in
            (tool == .compatibility ? compatibilityInputTitle : tool.title, tool.symbol, { [weak self] in
                self?.activateTool(tool)
            })
        } + [("定制工具栏", "rectangle.3.group.fill", { [weak self] in self?.showToolbarEditor() })]
        buildGrid(items, in: stack, identifiers: [compatibilityInputTitle: "keyboard.compatibleInput"]); finishPanelTransition()
    }
    private var compatibilityInputTitle: String {
        model.settings.localPinyinComposition == true ? "兼容输入 · 开" : "兼容输入 · 关"
    }
    func toggleLocalPinyinComposition() {
        guard model.composition.isEmpty else { return }
        model.settings.localPinyinComposition = model.settings.localPinyinComposition == true ? nil : true
        updateToolbarState()
        allPanelViews(panel).compactMap { $0 as? ToolTileButton }.first {
            $0.accessibilityIdentifier == "keyboard.compatibleInput"
        }?.updateCaption(compatibilityInputTitle)
    }
    private func allPanelViews(_ view: UIView?) -> [UIView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { allPanelViews($0) }
    }
    func showToolbarEditor() {
        if toolbarEditing, panel != nil { updateToolbarState(); return }
        preparePanelTransition(); toolbarEditing = true; editorPulse()
        let stack = panelStack(title: "定制工具栏")
        let tools = ToolbarTool.allCases.filter { $0 != .language }
        for start in stride(from: 0, to: tools.count, by: 3) {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 8; row.distribution = .fillEqually
            for index in start..<min(start + 3, tools.count) {
                let tool = tools[index]
                let tile = ToolTileButton(title: tool.title, symbol: tool.symbol) { [weak self] in
                    guard let self else { return }
                    self.editorPulse()
                    self.setToolPinned(tool, pinned: !self.model.settings.toolbar.contains(tool))
                }
                tile.accessibilityIdentifier = "toolbar.editor." + tool.rawValue
                tile.heightAnchor.constraint(equalToConstant: 60).isActive = true
                tile.configureManagement(title: tool.title, pinned: model.settings.toolbar.contains(tool))
                editorTiles[tool] = tile; row.addArrangedSubview(tile)
            }
            while row.arrangedSubviews.count < 3 { row.addArrangedSubview(UIView()) }
            stack.addArrangedSubview(row)
        }
        finishPanelTransition()
    }
    private func buildGrid(_ items: [(String, String, () -> Void)], in stack: UIStackView, identifiers: [String: String] = [:]) {
        for start in stride(from: 0, to: items.count, by: 3) {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 8; row.distribution = .fillEqually
            for offset in 0..<3 {
                guard start + offset < items.count else { row.addArrangedSubview(UIView()); continue }
                let (title, symbol, action) = items[start + offset]
                let button = ToolTileButton(title: title, symbol: symbol) { [weak self] in self?.toolbarPulse(); action() }
                button.accessibilityIdentifier = identifiers[title]
                button.heightAnchor.constraint(equalToConstant: 60).isActive = true; row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
        }
    }
    private func showPanel(_ kind: ToolbarTool, detail: AppearanceItem? = nil) {
        if kind == .appearance, panelKind == .appearance, let nativeAppearance {
            let region = keyGlassGroup.frame.union(nativeAppearance.frame).intersection(bounds)
            panelTransition.begin(in: self, region: region)
            nativeAppearance.show(detail); activeTool = detail.flatMap { item in ToolbarTool.allCases.first { appearanceItem(for: $0) == item } } ?? kind; finishPanelTransition(); return
        }
        preparePanelTransition(); panelKind = kind; activeTool = kind
        if kind == .clipboard || kind == .phrases {
            model.startClipboardCapture(userRequested: true)
            let content = ClipboardPanel(model: model, showPhrases: kind == .phrases, completionInToolbar: true)
            content.onClose = { [weak self] in self?.closePanel() }
            content.onSelectionStateChanged = { [weak self] in self?.updateToolbarState(); self?.setNeedsLayout() }
            addSubview(content); panel = content; keyGlassGroup.isHidden = true; finishPanelTransition(); return
        }
        if kind == .vibration {
            let content = KeyboardHapticPanel(current: { [weak model] in model?.settings ?? KeyboardSettings() }, save: { [weak model] in model?.settings = $0 })
            panel = content; addSubview(content); finishPanelTransition(); return
        }
        if kind == .appearance {
            let content = appearancePanelCache ?? KeyboardAppearancePanelView(current: { [weak model] in model?.settings ?? KeyboardSettings() },
                save: { [weak model] in model?.settings = $0 })
            appearancePanelCache = content; nativeAppearance = content; panel = content
            content.onNavigate = { [weak self] item in
                self?.toolbarPulse(); self?.showPanel(.appearance, detail: item)
            }
            content.show(detail)
            activeTool = detail.flatMap { item in ToolbarTool.allCases.first { appearanceItem(for: $0) == item } } ?? kind
            addSubview(content); keyGlassGroup.isHidden = true; finishPanelTransition(); return
        }
        let stack = panelStack(title: kind.title)
        switch kind {
        case .clipboard, .phrases: break
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
        case .compatibility: toggleLocalPinyinComposition()
        case .keyGlass, .keyColor, .textColor, .textSize, .vibration: activateTool(kind)
        }
        finishPanelTransition()
    }
    private func actionButton(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = FeedbackButton(type: .system); button.setTitle(title, for: .normal)
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
