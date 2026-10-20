import UIKit
import ImageIO

@MainActor final class KeyboardSurface: UIView, UIDragInteractionDelegate, UIDropInteractionDelegate {
    let model: KeyboardModel
    let systemBacked: Bool
    var onHeightChange: ((CGFloat) -> Void)?
    var configureGlobe: ((UIButton) -> Void)? { didSet { layoutSignature = ""; render() } }
    private let backdrop = GlassBackdrop()
    private let toolbar = UIStackView()
    private let candidateScroll = CandidateScrollView()
    private let hint = UILabel()
    private let keyGlassGroup = UIView()
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
    var isInteractingWithCandidates: Bool { candidateScroll.holdsCandidateUpdates }
    private var candidateHeight: CGFloat { movingCursor || !model.composition.isEmpty || !model.candidates.isEmpty || model.arithmetic != nil ? 44 : 0 }
    private var headerHeight: CGFloat { KeyboardGeometry.headerHeight }
    private var metrics: KeyboardGeometry.Metrics { KeyboardGeometry.Metrics(keyHeight: model.settings.keyHeight) }
    var desiredHeight: CGFloat { metrics.contentHeight }

    init(model: KeyboardModel, systemBacked: Bool = false) {
        self.model = model; self.systemBacked = systemBacked; super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear; clipsToBounds = !systemBacked; addSubview(backdrop)
        layer.cornerCurve = .continuous; layer.cornerRadius = systemBacked ? 0 : 28
        // Remote hosts may advertise a much larger corner radius; never inherit it.
        if #available(iOS 26.0, *) { cornerConfiguration = .corners(radius: .fixed(systemBacked ? 0 : 28)) }
        toolbar.axis = .horizontal; toolbar.distribution = .fill; toolbar.alignment = .center; toolbar.spacing = 10
        addSubview(toolbar)
        addSubview(candidateScroll)
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
        sideRail.axis = .vertical; sideRail.distribution = .fillEqually; sideRail.spacing = 6
        addSubview(deleteHint); deleteHint.isHidden = true; deleteHint.isUserInteractionEnabled = false
        deleteHint.font = .systemFont(ofSize: 13, weight: .semibold); deleteHint.textAlignment = .center
        deleteHint.textColor = .white; deleteHint.layer.cornerRadius = 10; deleteHint.clipsToBounds = true
        model.onChange = { [weak self] in
            guard let self else { return }
            let raw = self.model.composition.raw
            if self.requestedSpelling != raw {
                self.requestedSpelling = raw; self.candidateScroll.inputChanged()
            }
            self.render()
        }
        // A result belongs to the collection, not to the whole remote keyboard's
        // layout. Native scrolling and key geometry need no layout invalidation.
        model.onCandidatesChange = { [weak self] in self?.renderCandidates() }
        model.onInputChange = { [weak self] in self?.renderInput() }
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
            guard let self, self.panelKind == .clipboard else { return }
            (self.panel as? ClipboardPanel)?.reloadFromDisk()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { observerTokens.forEach { NotificationCenter.default.removeObserver($0) } }

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
            backdrop.frame = bounds; toolbar.frame = layout.header
            keyGlassGroup.frame = layout.keys
            for (button, row, start, units) in keys {
                button.frame = CGRect(x: CGFloat(start) * layout.unitWidth, y: CGFloat(row) * layout.rowPitch,
                                      width: CGFloat(units) * layout.unitWidth, height: layout.rowPitch)
            }
            sideRail.isHidden = settings.hand == .full
            sideRail.frame = layout.sideRail
        }
        var header = layout.header; header.size.height = candidateHeight
        if candidateScroll.frame != header { candidateScroll.frame = header }
        hint.frame = header
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
        let signature = "\(model.page)-\(model.document?.needsGlobe ?? true)"
        if signature != layoutSignature && !movingCursor {
            layoutSignature = signature
            keys.forEach { $0.0.removeFromSuperview() }; keys = []
            for (rowIndex, row) in KeyboardLayout.rows(page: model.page, uppercase: uppercase, globe: model.document?.needsGlobe ?? true).enumerated() {
                var start = row.insetUnits
                for key in row.keys {
                    let button = KeyButton(key: key)
                    button.onInteractionChanged = { [weak model] active in
                        model?.document?.keyInteractionChanged(active)
                        if !active { model?.cancelPreparation() }
                    }
                    button.onPrepare = { [weak model] action in model?.prepare(action) }
                    if key.action == .globe, let configureGlobe { configureGlobe(button) }
                    else { button.onAction = { [weak model] action in model?.handle(action) } }
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
        let toolSignature = "\(settings.toolbar)-\(toolbarEditing)-\(toolboxVisible)"
        if toolSignature != toolbarSignature { toolbarSignature = toolSignature; rebuildToolbar() }
        if railMode != settings.hand { railMode = settings.hand; rebuildRail() }
        let style = "\(settings.glass)-\(settings.accent)-\(settings.customAccentHex ?? "")-\(settings.glassOpacity)-\(settings.haptics)-\(traitCollection.userInterfaceStyle.rawValue)"
        let appearanceChanged = style != appearanceSignature
        if appearanceChanged {
            appearanceSignature = style; backdrop.apply(settings, systemBacked: systemBacked); tintColor = settings.accentInkColor
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
        let height = candidateHeight
        if presentedHeaderHeight != height {
            presentedHeaderHeight = height
            var frame = candidateScroll.frame; frame.size.height = height; candidateScroll.frame = frame
            setNeedsLayout()
        }
        let displayed = model.arithmetic?.candidates.map { Candidate(text: $0, consumed: 0) } ?? model.candidates
        // A result can arrive before the first host layout. Do not ask a zero-
        // sized flow layout to lay out 44-point cells; layout will pull the latest.
        if height > 0, candidateScroll.bounds.width > 0 {
            candidateScroll.update(displayed, context: model.candidateContext, arithmetic: model.arithmetic != nil, accent: model.settings.accentInkColor, hasMore: model.hasMoreCandidates)
        }
        toolbar.isHidden = panelKind == .clipboard || candidateHeight > 0
        candidateScroll.isHidden = panelKind == .clipboard || movingCursor || candidateHeight == 0
        hint.isHidden = !movingCursor; hint.text = movingCursor ? "滑动键盘，移动光标" : nil
        // Candidate updates only touch the header, never the keys or glass layers.
        // The collection lays out in UIKit's normal pass, never synchronously
        // from a key event or a decoder completion.
    }
    private func circleButton(symbol: String? = nil, image: UIImage? = nil, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = image ?? symbol.map { ToolArtwork.image(symbol: $0, size: 28) }
        config.baseForegroundColor = .secondaryLabel
        config.background.backgroundColor = .clear
        config.background.cornerRadius = 0
        config.contentInsets = .zero
        button.configuration = config; button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    private func rebuildToolbar() {
        toolbar.arrangedSubviews.forEach { toolbar.removeArrangedSubview($0); $0.removeFromSuperview() }
        let brand = circleButton(symbol: toolbarEditing ? "checkmark" : (toolboxVisible ? "chevron.down" : nil),
            image: toolbarEditing || toolboxVisible ? nil : ToolArtwork.brand(size: 28), label: toolbarEditing ? "完成工具栏编辑" : "键盘工具") { [weak self] in
                guard let self else { return }
                if self.toolbarEditing { self.closePanel() }
                else if self.toolboxVisible { self.closePanel() }
                else { self.showToolbox() }
            }
        brand.configuration?.baseForegroundColor = model.settings.accentInkColor
        brand.accessibilityIdentifier = "toolbar.tools"
        toolbar.addArrangedSubview(brand)
        let spacer = UIView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); toolbar.addArrangedSubview(spacer)
        for tool in model.settings.toolbar.filter({ $0 != .language }).prefix(3) {
            let button = circleButton(symbol: tool.symbol, label: tool.title) { [weak self] in
                guard let self else { return }
                if self.toolbarEditing { self.setToolPinned(tool, pinned: false) }
                else { self.activateTool(tool) }
            }
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
            toolbar.addArrangedSubview(button)
        }
    }
    @objc private func editToolbar(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began && !toolbarEditing { showToolbarEditor() } }
    func setToolPinned(_ tool: ToolbarTool, pinned: Bool) {
        guard tool != .language else { return }
        var tools = model.settings.toolbar
        if pinned {
            guard !tools.contains(tool) else { return }
            guard tools.filter({ $0 != .language }).count < 3 else { announce("先移除一个工具，再添加"); return }
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
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard toolbarEditing, let identifier = interaction.view?.accessibilityIdentifier,
              let tool = ToolbarTool(rawValue: identifier.replacingOccurrences(of: "toolbar.", with: "")) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: tool.rawValue as NSString)); item.localObject = tool; return [item]
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool { toolbarEditing && session.localDragSession != nil }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal { UIDropProposal(operation: toolbarEditing ? .move : .cancel) }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let tool = session.items.first?.localObject as? ToolbarTool, let identifier = interaction.view?.accessibilityIdentifier,
              let target = ToolbarTool(rawValue: identifier.replacingOccurrences(of: "toolbar.", with: "")) else { return }
        reorderToolbarTool(tool, before: target)
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
            var config = UIButton.Configuration.plain(); config.title = title; config.image = UIImage(systemName: symbol)
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
        panel?.removeFromSuperview(); panel = nil; panelKind = nil; toolboxVisible = false; toolbarEditing = false
        keyGlassGroup.isHidden = false; render()
    }
    private func activateTool(_ tool: ToolbarTool) {
        if tool == .oneHand {
            closePanel()
            model.settings.hand = model.settings.hand == .right ? .left : .right
        } else if tool == .language { closePanel(); model.toggleLanguage() }
        else { showPanel(tool) }
    }
    func stopInteractions() { keys.forEach { $0.0.stopTracking() }; setCursorMode(false); closePanel() }
    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
    private func panelStack(title: String) -> UIStackView {
        let container = UIView(); container.backgroundColor = .clear
        addSubview(container); panel = container; keyGlassGroup.isHidden = true
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor), scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24)])
        let header = UIStackView(); header.axis = .horizontal
        let label = UILabel(); label.text = title; label.font = .systemFont(ofSize: 14, weight: .semibold); header.addArrangedSubview(label)
        header.addArrangedSubview(actionButton("完成") { [weak self] in self?.closePanel() }); stack.addArrangedSubview(header)
        return stack
    }
    private func showToolbox() {
        closePanel(); toolboxVisible = true
        let stack = panelStack(title: "键盘工具")
        let items: [(String, String, () -> Void)] = ToolbarTool.allCases.map { tool in
            (tool == .language ? "中 / EN" : tool.title, tool.symbol, { [weak self] in
                self?.activateTool(tool)
            })
        } + [("定制工具栏", "rectangle.3.group.fill", { [weak self] in self?.showToolbarEditor() })]
        buildGrid(items, in: stack); render()
    }
    private func showToolbarEditor() {
        closePanel(); toolbarEditing = true; toolboxVisible = true
        let stack = panelStack(title: "定制工具栏")
        stack.addArrangedSubview(note("点按添加或移除 · 按住上方图标拖动排序"))
        let items: [(String, String, () -> Void)] = ToolbarTool.allCases.filter { $0 != .language }.map { tool in
            let selected = model.settings.toolbar.contains(tool)
            return ((selected ? "− " : "+ ") + tool.title, tool.symbol, { [weak self] in self?.setToolPinned(tool, pinned: !selected) })
        }
        buildGrid(items, in: stack); render()
    }
    private func buildGrid(_ items: [(String, String, () -> Void)], in stack: UIStackView) {
        for start in stride(from: 0, to: items.count, by: 3) {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 8; row.distribution = .fillEqually
            for offset in 0..<3 {
                guard start + offset < items.count else { row.addArrangedSubview(UIView()); continue }
                let (title, symbol, action) = items[start + offset]
                var config = UIButton.Configuration.plain(); config.title = title; config.image = ToolArtwork.image(symbol: symbol, size: 32)
                config.imagePlacement = .top; config.imagePadding = 7; config.baseForegroundColor = .label
                config.background.backgroundColor = UIColor.tertiarySystemFill.withAlphaComponent(0.18); config.background.cornerRadius = 14
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in var result = values; result.font = .systemFont(ofSize: 11); return result }
                let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
                button.heightAnchor.constraint(equalToConstant: 76).isActive = true; row.addArrangedSubview(button)
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
            let width = UISlider(); width.minimumValue = 0.68; width.maximumValue = 0.88; width.value = Float(model.settings.oneHandFraction)
            width.accessibilityLabel = "单手键盘宽度"
            width.addAction(UIAction { [weak self, weak width] _ in if let width { self?.model.settings.oneHandWidth = Double(width.value) } }, for: .valueChanged)
            stack.addArrangedSubview(width)
            stack.addArrangedSubview(note("按键高度"))
            let height = UISlider(); height.minimumValue = 44; height.maximumValue = 58; height.value = Float(model.settings.keyHeight)
            height.accessibilityLabel = "按键高度"
            height.addAction(UIAction { [weak self, weak height] _ in if let height { self?.model.settings.keyHeight = Double(height.value.rounded()) } }, for: .valueChanged)
            stack.addArrangedSubview(height)
        case .appearance:
            let segment = UISegmentedControl(items: GlassPreset.allCases.map(\.title))
            segment.selectedSegmentIndex = GlassPreset.allCases.firstIndex(of: model.settings.glass) ?? 0
            segment.addAction(UIAction { [weak self, weak segment] _ in guard let segment else { return }; self?.model.settings.glass = GlassPreset.allCases[segment.selectedSegmentIndex] }, for: .valueChanged)
            stack.addArrangedSubview(segment)
            let slider = UISlider(); slider.minimumValue = 0.15; slider.maximumValue = 1; slider.value = Float(model.settings.glassOpacity)
            slider.accessibilityLabel = "玻璃遮罩浓度"
            slider.addAction(UIAction { [weak self, weak slider] _ in if let slider { self?.model.settings.glassOpacity = Double(slider.value) } }, for: .valueChanged)
            stack.addArrangedSubview(slider)
            let colors = UIStackView(); colors.axis = .horizontal; colors.distribution = .fillEqually
            for color in Accent.allCases { colors.addArrangedSubview(actionButton(color.title) { [weak self] in self?.model.settings.accent = color; self?.model.settings.customAccentHex = nil }) }
            stack.addArrangedSubview(colors)
            for (channel, name) in ["R", "G", "B"].enumerated() {
                let row = UIStackView(); row.axis = .horizontal; row.spacing = 8
                let label = note(name); label.widthAnchor.constraint(equalToConstant: 15).isActive = true; row.addArrangedSubview(label)
                let rgb = model.settings.accentRGB
                let slider = UISlider(); slider.minimumValue = 0; slider.maximumValue = 255; slider.tag = channel
                slider.value = Float([rgb.red, rgb.green, rgb.blue][channel] * 255); slider.accessibilityLabel = "自定义颜色 " + name
                slider.addAction(UIAction { [weak self, weak slider] _ in
                    guard let self, let slider else { return }; var color = self.model.settings.accentRGB
                    let value = Double(slider.value) / 255
                    if slider.tag == 0 { color.red = value } else if slider.tag == 1 { color.green = value } else { color.blue = value }
                    self.model.settings.customAccentHex = color.hex
                }, for: .valueChanged); row.addArrangedSubview(slider); stack.addArrangedSubview(row)
            }
        }
        setNeedsLayout()
    }
    private func actionButton(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
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
        stack.addArrangedSubview(note("文字表情直接输入；文字贴纸点按复制，再到消息框粘贴。"))
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

