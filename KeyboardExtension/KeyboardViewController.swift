import UIKit
import os

@objc(ClearKeyboardViewController)
class KeyboardViewController: UIInputViewController, KeyboardDocument {
    private var model: KeyboardModel!
    private var surface: KeyboardSurface!
    private let rootBackdrop = GlassBackdrop()
#if DEBUG
    // Test evidence from the actual extension process, without exposing typed
    // content or replacing the root's accessible key hierarchy with a leaf.
    private let runtimeProbe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
#endif
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var surfaceHeightConstraint: NSLayoutConstraint?
    private var hostState = HostTextState()
    private var hostEnterTitle = "换行"
    private var hostCapitalization = UITextAutocapitalizationType.none
    private var hostPrefersEnglish = false
    private var hostNeedsGlobe = true
    private var hostRefresh: Timer?
    private var pendingMarkedText = LatestValue<String>()
    private let markedFrame = DisplayFrameTask()
    private var markedCadence = FrameWriteCadence()
    private var markedWriteGeneration = 0
    private var markedImmediateScheduled = false
    private var sentMarkedDraft = false
    private enum MarkedTransport: Equatable { case none, local, host }
    // A nil/nil proxy cannot demonstrate that it owns a replaceable marked
    // range. Some remote clients buffer these calls as literal keystrokes and
    // ignore an empty mark. Keep such spelling inside the keyboard instead.
    private var markedTransport = MarkedTransport.none
    private var markedDraft = ""
    private var readableHostContext = false
    private var hostRefreshGeneration = 0
    private var activeKeys = 0
    private var hostActive = true
    private var needsHostRefresh = false
    private var candidateSelectionNeedsValidation = false
    private var hostWriteDepth = 0
    private var hostNotificationRevision = 0
    private var deferredMarkedFlush = false
    private var trackpad: ProxyTrackpad?
    private var lastLayoutLog = ""
    private var layoutLogCount = 0
    private let hostLog = OSLog(subsystem: "ClearKeyboard", category: "HostWrite")

#if DEBUG && (SHELL_AB_DEFAULT_ROOT || SHELL_AB_KEYBOARD_ROOT || SHELL_AB_HOST_SIZED_ROOT || SHELL_MATERIAL_A || SHELL_MATERIAL_B || SHELL_MATERIAL_C)
    // Isolated diagnostic only: public root construction and a fixed test tint.
    // Do not inspect or alter UIKit's external shell, cap or globe container.
    private static var shellABBlue: UIColor {
        UIColor(red: 85.0 / 255.0, green: 141.0 / 255.0, blue: 242.0 / 255.0, alpha: 1)
    }
    private var shellABRecipe: String {
#if (SHELL_AB_DEFAULT_ROOT && SHELL_AB_KEYBOARD_ROOT) || (SHELL_AB_HOST_SIZED_ROOT && (SHELL_AB_DEFAULT_ROOT || SHELL_AB_KEYBOARD_ROOT)) || ((SHELL_MATERIAL_A || SHELL_MATERIAL_B || SHELL_MATERIAL_C) && (SHELL_AB_DEFAULT_ROOT || SHELL_AB_KEYBOARD_ROOT || SHELL_AB_HOST_SIZED_ROOT)) || (SHELL_MATERIAL_A && SHELL_MATERIAL_B) || (SHELL_MATERIAL_A && SHELL_MATERIAL_C) || (SHELL_MATERIAL_B && SHELL_MATERIAL_C)
#error("Select exactly one public keyboard-shell recipe")
#elseif SHELL_MATERIAL_A
        return "material-a-blur-tint055"
#elseif SHELL_MATERIAL_B
        return "material-b-no-blur-tint055"
#elseif SHELL_MATERIAL_C
        return "material-c-no-blur-opaque"
#elseif SHELL_AB_DEFAULT_ROOT
        return "default-root"
#elseif SHELL_AB_HOST_SIZED_ROOT
        return "host-sized-default-root"
#else
        return "keyboard-root"
#endif
    }
    override func loadView() {
#if SHELL_AB_DEFAULT_ROOT || SHELL_AB_HOST_SIZED_ROOT || SHELL_MATERIAL_A || SHELL_MATERIAL_B || SHELL_MATERIAL_C
        let root = UIInputView(frame: .zero, inputViewStyle: .default)
#else
        let root = UIInputView(frame: .zero, inputViewStyle: .keyboard)
#endif
#if SHELL_MATERIAL_A || SHELL_MATERIAL_B || SHELL_MATERIAL_C
        root.backgroundColor = .clear
#else
        root.backgroundColor = Self.shellABBlue
#endif
        root.isOpaque = false
        inputView = root
    }
#endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; view.isOpaque = false
#if DEBUG && (SHELL_AB_DEFAULT_ROOT || SHELL_AB_KEYBOARD_ROOT || SHELL_AB_HOST_SIZED_ROOT)
        // The normal initializer deliberately clears the root. Reapply the
        // experiment tint here, before adding the unchanged internal backdrop.
        view.backgroundColor = Self.shellABBlue
#endif
        view.accessibilityIdentifier = "clear.keyboard.root"
#if DEBUG
        runtimeProbe.isUserInteractionEnabled = false
        runtimeProbe.isAccessibilityElement = true
        runtimeProbe.accessibilityIdentifier = "clear.keyboard.runtime"
        runtimeProbe.accessibilityLabel = "Keyboard runtime evidence"
        view.addSubview(runtimeProbe)
#endif
        inputView?.allowsSelfSizing = false
        refreshHostState(refreshTraits: true)
        // Only the real extension acknowledges an App appearance revision.
        // App previews and hosted test models must not produce that receipt.
        let appearanceLink: AppearanceSettingsLink? = Bundle.main.bundleURL.pathExtension == "appex"
            ? .production(role: .keyboard) : nil
        model = KeyboardModel(document: self, appearanceLink: appearanceLink)
        // Keep one backdrop inside the primary view. A chosen skin paints that
        // whole owned area; do not fade its edges to simulate control over the
        // external system cap and globe container.
        // Keys retain their fixed pitch and bottom anchoring, including when
        // the host temporarily allocates extra height. The system's external
        // rounded cap and globe container remain outside our drawing bounds.
        rootBackdrop.accessibilityIdentifier = "clear.keyboard.root-backdrop"
        rootBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootBackdrop)
        NSLayoutConstraint.activate([
            rootBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            rootBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
#if DEBUG && (SHELL_MATERIAL_A || SHELL_MATERIAL_B || SHELL_MATERIAL_C)
        rootBackdrop.materialABExperimentEnabled = true
#endif
        surface = KeyboardSurface(model: model, systemBacked: true, backgroundBackdrop: rootBackdrop)
        surface.configureGlobe = { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        view.addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        let contentHeight = surface.heightAnchor.constraint(equalToConstant: surface.desiredHeight)
        contentHeight.identifier = "clear.keyboard.surface-height"; surfaceHeightConstraint = contentHeight
#if DEBUG && SHELL_AB_HOST_SIZED_ROOT
        // Isolated geometry experiment: let UIKit allocate the primary view.
        // Keep the existing key pitch and reserve only this view's public safe
        // area. A zero bottom inset does not prove a system footer is included.
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            surface.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor),
            contentHeight
        ])
#else
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor), contentHeight
        ])
#endif
        surface.onHeightChange = { [weak self] height in self?.updateHeight(height) }
        updateHeight(surface.desiredHeight)

    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); hostActive = true; refreshHostState(refreshTraits: true); model?.reloadSettings()
        if let surface { updateHeight(surface.desiredHeight) }
    }
    override func updateViewConstraints() {
        if let surface { updateHeight(surface.desiredHeight) }
        super.updateViewConstraints()
    }
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        surface?.setNeedsLayout()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let surface { updateHeight(surface.desiredHeight) }
        model?.refreshAppearanceConnection()
        model?.startClipboardCapture()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let surface else { return }
        // A cached host frame is provisional, especially when Safari changes input traits.
        // Keep the requested key pitch while UIKit negotiates the remote view's final height.
        // Squeezing the surface into that frame permanently changed both key size and font size.
        // UIKit completes the normal layout pass. Forcing a second synchronous
        // subtree layout here makes host size acknowledgements contend with keys.
        let layout = "root=\(view.bounds) content=\(surface.frame) parent=\(view.superview?.bounds ?? .zero) window=\(view.window?.bounds ?? .zero)"
        if layout != lastLayoutLog && layoutLogCount < 12 {
            lastLayoutLog = layout; layoutLogCount += 1
            NSLog("CLEAR_KEYBOARD_LAYOUT %@", layout)
        }
        updateHeight(surface.desiredHeight)
#if DEBUG
        updateRuntimeEvidence()
#endif
    }
#if DEBUG
    private func updateRuntimeEvidence() {
        runtimeProbe.frame = CGRect(x: view.bounds.midX, y: 1, width: 1, height: 1)
        view.bringSubviewToFront(runtimeProbe)
        func rect(_ value: CGRect) -> [Double] {
            [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }
        let inset = view.safeAreaInsets
        let evidence: [String: Any] = [
            "bundleExtension": Bundle.main.bundleURL.pathExtension,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "hostActive": hostActive,
            "rootBounds": rect(view.bounds),
            "windowBounds": rect(view.window?.bounds ?? .zero),
            "safeAreaInsets": [Double(inset.top), Double(inset.left), Double(inset.bottom), Double(inset.right)]
        ]
#if DEBUG && (SHELL_AB_DEFAULT_ROOT || SHELL_AB_KEYBOARD_ROOT || SHELL_AB_HOST_SIZED_ROOT || SHELL_MATERIAL_A || SHELL_MATERIAL_B || SHELL_MATERIAL_C)
        var abEvidence = evidence
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let color = view.backgroundColor?.resolvedColor(with: traitCollection)
        let hasRGBA = color?.getRed(&red, green: &green, blue: &blue, alpha: &alpha) == true
        abEvidence["shellABRecipe"] = shellABRecipe
#if SHELL_MATERIAL_A || SHELL_MATERIAL_B || SHELL_MATERIAL_C
        abEvidence["shellABRequestedRootHex"] = "clear"
#else
        abEvidence["shellABRequestedRootHex"] = "#558DF2"
#endif
        abEvidence["shellABActualRootRGBA"] = hasRGBA ? [Double(red), Double(green), Double(blue), Double(alpha)] : []
        abEvidence["shellABActualRootClass"] = String(describing: type(of: view!))
        abEvidence["shellABActualInputViewStyle"] = inputView?.inputViewStyle.rawValue ?? -1
        // Read-only extension-owned geometry and UIWindow diagnostics.
        // Nothing here changes the window, ancestors, clipping or material.
        func resolvedRGBA(_ color: UIColor?, traits: UITraitCollection) -> [Double] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color?.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a) == true else { return [] }
            return [Double(r), Double(g), Double(b), Double(a)]
        }
        // Public read-only guide values are diagnostic hints, not evidence
        // that a guide owns or exposes the external native footer.
        abEvidence["rootSafeAreaLayoutFrame"] = rect(view.safeAreaLayoutGuide.layoutFrame)
        abEvidence["rootKeyboardLayoutFrame"] = rect(view.keyboardLayoutGuide.layoutFrame)
        abEvidence["surfaceBounds"] = rect(surface.bounds)
        abEvidence["surfaceFrameInRoot"] = rect(surface.convert(surface.bounds, to: view))
        abEvidence["rootHeightConstraintMode"] = heightConstraint.map { String(describing: $0.relation) } ?? "missing"
        abEvidence["rootHeightConstraintConstant"] = Double(heightConstraint?.constant ?? -1)
        abEvidence["rootHeightConstraintPriority"] = Double(heightConstraint?.priority.rawValue ?? -1)
        if let constraint = heightConstraint {
            abEvidence["rootHeightConstraintRelationRawValue"] = constraint.relation.rawValue
            abEvidence["rootHeightConstraintIsActive"] = constraint.isActive
            abEvidence["rootHeightConstraintFirstItemIsRoot"] = (constraint.firstItem as? UIView) === view
            abEvidence["rootHeightConstraintSecondItemIsNil"] = constraint.secondItem == nil
            abEvidence["rootHeightConstraintFirstAttributeRawValue"] = constraint.firstAttribute.rawValue
        } else {
            abEvidence["rootHeightConstraintRelationRawValue"] = NSNull()
            abEvidence["rootHeightConstraintIsActive"] = false
            abEvidence["rootHeightConstraintFirstItemIsRoot"] = false
            abEvidence["rootHeightConstraintSecondItemIsNil"] = NSNull()
            abEvidence["rootHeightConstraintFirstAttributeRawValue"] = NSNull()
        }
        abEvidence["rootClipsToBounds"] = view.clipsToBounds
        abEvidence["rootLayerMasksToBounds"] = view.layer.masksToBounds
        abEvidence["rootIsOpaque"] = view.isOpaque
        abEvidence["rootBackdropBounds"] = rect(rootBackdrop.bounds)
        abEvidence["rootBackdropClipsToBounds"] = rootBackdrop.clipsToBounds
        abEvidence["rootBackdropLayerMasksToBounds"] = rootBackdrop.layer.masksToBounds
        abEvidence["rootBackdropIsOpaque"] = rootBackdrop.isOpaque
        abEvidence["rootBackdropBackgroundRGBA"] = resolvedRGBA(rootBackdrop.backgroundColor, traits: rootBackdrop.traitCollection)
        // Only these two direct children belong to our GlassBackdrop. Do not
        // inspect UIKit's effect internals, host shell or private ancestors.
        abEvidence["ownedBackdropReadScope"] = "two-direct-owned-children-only"
        abEvidence["ownedBackdropChildCount"] = rootBackdrop.subviews.count
        abEvidence["ownedBackdropChildren"] = Array(rootBackdrop.subviews.prefix(2)).enumerated().map { pair -> [String: Any] in
            let (index, child) = pair
            var childEvidence: [String: Any] = [
                "role": index == 0 ? "material" : "wash",
                "publicClass": String(describing: type(of: child)),
                "bounds": rect(child.bounds),
                "frameInBackdrop": rect(child.frame),
                "alpha": Double(child.alpha),
                "isHidden": child.isHidden,
                "isOpaque": child.isOpaque,
                "clipsToBounds": child.clipsToBounds,
                "layerMasksToBounds": child.layer.masksToBounds,
                "backgroundRGBA": resolvedRGBA(child.backgroundColor, traits: child.traitCollection)
            ]
            if let effectView = child as? UIVisualEffectView {
                childEvidence["expectedOwnedRoleType"] = index == 0
                childEvidence["effectPresent"] = effectView.effect != nil
                childEvidence["effectPublicClass"] = effectView.effect.map { String(describing: type(of: $0)) } ?? "none"
            } else {
                childEvidence["expectedOwnedRoleType"] = index == 1
                childEvidence["effectPresent"] = false
                childEvidence["effectPublicClass"] = "not-an-effect-view"
            }
            if let mask = child.mask {
                childEvidence["maskBounds"] = rect(mask.bounds)
                childEvidence["maskFrame"] = rect(mask.frame)
                childEvidence["maskAlpha"] = Double(mask.alpha)
                childEvidence["maskBackgroundRGBA"] = resolvedRGBA(mask.backgroundColor, traits: mask.traitCollection)
            } else {
                childEvidence["maskBounds"] = NSNull()
                childEvidence["maskFrame"] = NSNull()
                childEvidence["maskAlpha"] = NSNull()
                childEvidence["maskBackgroundRGBA"] = NSNull()
            }
            if let window = view.window {
                childEvidence["frameInWindow"] = rect(child.convert(child.bounds, to: window))
            } else { childEvidence["frameInWindow"] = NSNull() }
            return childEvidence
        }
        // Appearance inputs only. No draft, candidates, proxy or typed content.
        abEvidence["backgroundAppearanceInputs"] = [
            "glass": model.settings.glass.rawValue,
            "backgroundResolvedStrength": model.settings.resolvedBackgroundGlassStrength,
            "backgroundStrengthWasExplicit": model.settings.backgroundGlassStrength != nil,
            "backgroundHex": model.settings.backgroundColorHex ?? "auto",
            "glassOpacity": model.settings.glassOpacity,
            "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled
        ] as [String: Any]
#if SHELL_MATERIAL_A || SHELL_MATERIAL_B || SHELL_MATERIAL_C
        abEvidence["materialABForcedAppearance"] = rootBackdrop.materialABExperimentEnabled
        abEvidence["materialABAppearanceSource"] = "extension-owned-in-process-copy-through-production-GlassBackdrop.apply"
        abEvidence["materialABAppGroupSynchronizationVerified"] = false
        abEvidence["materialABModelSettingsMutatedByDiagnostic"] = false
        if let actualNativeDefault = rootBackdrop.materialABActualNativeDefault {
            abEvidence["materialABActualNativeDefault"] = actualNativeDefault
        } else { abEvidence["materialABActualNativeDefault"] = NSNull() }
        abEvidence["materialABObservedModelAppearance"] = [
            "glass": model.settings.glass.rawValue,
            "backgroundHex": model.settings.backgroundColorHex ?? "auto",
            "keyHex": model.settings.keyColorHex ?? "auto",
            "keyResolvedStrength": model.settings.resolvedKeyGlassStrength,
            "keyHeight": model.settings.keyHeight,
            "hand": model.settings.hand.rawValue
        ] as [String: Any]
        if let applied = rootBackdrop.materialABAppliedBackgroundSettings {
            abEvidence["materialABActualAppliedBackgroundSettings"] = [
                "glass": applied.glass.rawValue,
                "glassOpacity": applied.glassOpacity,
                "backgroundResolvedStrength": applied.resolvedBackgroundGlassStrength,
                "backgroundStrengthWasExplicit": applied.backgroundGlassStrength != nil,
                "backgroundHex": applied.backgroundColorHex ?? "auto",
                "systemBacked": rootBackdrop.materialABActualSystemBacked ?? false
            ] as [String: Any]
        } else { abEvidence["materialABActualAppliedBackgroundSettings"] = NSNull() }
        abEvidence["materialABRootAlpha"] = Double(view.alpha)
        abEvidence["materialABBackdropAlpha"] = Double(rootBackdrop.alpha)
#endif
        if let window = view.window {
            let windowInsets = window.safeAreaInsets
            abEvidence["windowSafeAreaLayoutFrame"] = rect(window.safeAreaLayoutGuide.layoutFrame)
            abEvidence["windowKeyboardLayoutFrame"] = rect(window.keyboardLayoutGuide.layoutFrame)
            abEvidence["surfaceFrameInWindow"] = rect(surface.convert(surface.bounds, to: window))
            abEvidence["rootFrameInWindow"] = rect(view.convert(view.bounds, to: window))
            abEvidence["rootBackdropFrameInWindow"] = rect(rootBackdrop.convert(rootBackdrop.bounds, to: window))
            abEvidence["windowSafeAreaInsets"] = [Double(windowInsets.top), Double(windowInsets.left), Double(windowInsets.bottom), Double(windowInsets.right)]
            abEvidence["windowBackgroundRGBA"] = resolvedRGBA(window.backgroundColor, traits: window.traitCollection)
            abEvidence["windowHasBackgroundColor"] = window.backgroundColor != nil
            abEvidence["windowIsOpaque"] = window.isOpaque
        } else {
            abEvidence["rootFrameInWindow"] = NSNull()
            abEvidence["rootBackdropFrameInWindow"] = NSNull()
            abEvidence["windowSafeAreaInsets"] = NSNull()
            abEvidence["windowBackgroundRGBA"] = NSNull()
            abEvidence["windowHasBackgroundColor"] = false
            abEvidence["windowIsOpaque"] = NSNull()
        }
        if let actualInputView = inputView {
            abEvidence["inputViewAllowsSelfSizing"] = actualInputView.allowsSelfSizing
            abEvidence["inputViewClass"] = String(describing: type(of: actualInputView))
            abEvidence["inputViewStyle"] = actualInputView.inputViewStyle.rawValue
        } else {
            abEvidence["inputViewClass"] = NSNull()
            abEvidence["inputViewStyle"] = NSNull()
        }
        abEvidence["shellABUsesOnlyPublicRootAPI"] = true
        abEvidence["shellABExternalChromeModified"] = false
        if let data = try? JSONSerialization.data(withJSONObject: abEvidence, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) {
            runtimeProbe.accessibilityValue = value
        }
#else
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) {
            runtimeProbe.accessibilityValue = value
        }
#endif
    }
#endif
    private func updateHeight(_ height: CGFloat) {
        if abs((surfaceHeightConstraint?.constant ?? 0) - height) > 0.5 { surfaceHeightConstraint?.constant = height }
        view.translatesAutoresizingMaskIntoConstraints = false
        if heightConstraint == nil {
#if DEBUG && SHELL_AB_HOST_SIZED_ROOT
            // A minimum protects keys without asserting that content height is
            // the full allocated backdrop height. Do not use a window, native
            // shell, historical 17pt cap or footer constant as the root size.
            let constraint = view.heightAnchor.constraint(greaterThanOrEqualToConstant: height)
            constraint.identifier = "clear.keyboard.minimum-content-height"
#else
            let constraint = view.heightAnchor.constraint(equalToConstant: height)
            constraint.identifier = "clear.keyboard.content-height"
#endif
            constraint.priority = .required; constraint.isActive = true; heightConstraint = constraint
        } else if abs((heightConstraint?.constant ?? 0) - height) > 0.5 { heightConstraint?.constant = height }
        let hostWidth = KeyboardGeometry.fittingWidth(primary: view.bounds.width,
            container: view.superview?.bounds.width ?? 0, window: view.window?.bounds.width ?? 0)
        guard hostWidth.isFinite, hostWidth > 0 else { return }
        // UIKit owns the available width. A lower-priority fallback gives its native
        // fitting pass a nonzero width without fighting required host constraints.
        // Never treat a remote window's full width or height as the keyboard's size.
        if widthConstraint == nil {
            let constraint = view.widthAnchor.constraint(equalToConstant: hostWidth)
            constraint.identifier = "clear.keyboard.system-width"; constraint.priority = .defaultHigh
            constraint.isActive = true; widthConstraint = constraint
        } else if abs((widthConstraint?.constant ?? 0) - hostWidth) > 0.5 { widthConstraint?.constant = hostWidth }
#if DEBUG && SHELL_AB_HOST_SIZED_ROOT
        // UIKit chooses from the current layout instead of being told to use
        // our exact fitting height. This is not a promise of any extra area.
        if inputView?.allowsSelfSizing != false { inputView?.allowsSelfSizing = false }
#else
        if inputView?.allowsSelfSizing != true { inputView?.allowsSelfSizing = true }
#endif
    }
    override func viewWillDisappear(_ animated: Bool) {
        hostActive = false
        hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil
        super.viewWillDisappear(animated); surface?.stopInteractions()
        // Dismissing the keyboard is not an explicit request to send a local
        // spelling to an unreadable remote editor.
        if markedTransport == .local { abandonDraftWithoutHostWrite() }
        else { model?.finishCompositionAsTyped() }
        model?.suspend()
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        hostNotificationRevision += 1
        if model?.isMovingCursor == true { return }
        // Even the identity getter can cross the remote-host boundary. A text
        // acknowledgement must not do synchronous proxy reads in a key's frame.
        needsHostRefresh = true
        scheduleHostRefresh()
    }
    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        hostNotificationRevision += 1
        guard model?.isMovingCursor != true else { return }
        candidateSelectionNeedsValidation = true
        // Reconcile the captured selection/UUID before using an old candidate.
        // Nil/nil clients may deliver a delayed acknowledgement of a partial
        // insertion here; a notification alone cannot identify a moved caret.
        needsHostRefresh = true; scheduleHostRefresh()
    }
    func keyInteractionChanged(_ active: Bool) {
        activeKeys = max(0, activeKeys + (active ? 1 : -1))
        if active { hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil }
        else if activeKeys == 0, needsHostRefresh { scheduleHostRefresh() }
    }
    func candidateInteractionChanged(_ active: Bool) {
        if active { hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil }
        else if needsHostRefresh { scheduleHostRefresh() }
    }
    private func scheduleHostRefresh() {
        hostRefresh?.invalidate(); hostRefresh = nil
        guard hostActive, activeKeys == 0, hostWriteDepth == 0 else { return }
        hostRefreshGeneration += 1; let request = hostRefreshGeneration
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hostRefreshGeneration == request,
                      self.hostActive, self.activeKeys == 0 else { return }
                self.hostRefresh = nil
                // Read UIKit's actual tracking state, not a latched gesture flag.
                // In particular, the next touch may already own a coasting row.
                if self.surface?.isInteractingWithCandidates == true { self.scheduleHostRefresh(); return }
                self.refreshHostState()
            }
        }
        hostRefresh = timer
        RunLoop.main.add(timer, forMode: .default)
    }
    private func readHostSnapshot() -> (snapshot: HostTextSnapshot, connected: Bool) {
        // A temporarily unavailable remote identifier is not evidence that the
        // user switched fields. Treating nil as a new "disconnected" document
        // unmarked long input and cleared its candidates before a tap committed.
        guard let identifier = connectedDocumentIdentifier()?.uuidString else {
            var unavailable = hostState.snapshot
            unavailable.available = false
            return (unavailable, false)
        }
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        return (HostTextSnapshot(before: before ?? "", after: after ?? "", selected: textDocumentProxy.selectedText ?? "",
            document: identifier, available: before != nil || after != nil), true)
    }
    private func refreshHostState(refreshTraits: Bool = false) {
        guard hostWriteDepth == 0 else { needsHostRefresh = true; return }
        needsHostRefresh = false
        let revision = hostRefreshGeneration
        let read = readHostSnapshot(), actual = read.snapshot
        // A remote getter may service UIKit callbacks before returning. A key
        // or another notification in that interval invalidates this read; it
        // cannot cancel a newer spelling or unmark its first letter.
        guard revision == hostRefreshGeneration else {
            needsHostRefresh = true; scheduleHostRefresh(); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let wasReadable = readableHostContext
        let transportAccepted = !read.connected || observeContextReadability(actual)
        let outcome: HostTextState.Reconciliation
        if !transportAccepted || (read.connected && !actual.available && !actual.selected.isEmpty) {
            hostState = HostTextState(actual); outcome = .externalEdit
        } else if read.connected, !wasReadable, actual.available, actual.selected.isEmpty,
                  actual.document == hostState.snapshot.document, markedTransport == .local, !markedDraft.isEmpty {
            // Context becoming readable is not a request to flush local pinyin.
            // Rebase the local-only mark on the newly exposed real boundary.
            rebaseLocalDraft(on: actual)
            outcome = .compositionContextChanged
        } else { outcome = hostState.reconcile(actual, now: now) }
        guard outcome != .unavailable else {
            // A connected nil/nil field is a supported local-composition mode,
            // not a transient disconnection to poll every 350 ms indefinitely.
            if !read.connected { needsHostRefresh = true; scheduleHostRefresh() }
            return
        }
        candidateSelectionNeedsValidation = hostState.shouldRecheck(actual, now: now)
        // Traits belong to the field. Own text acknowledgements must not fetch
        // all of them again after each confirmed word.
        if refreshTraits || outcome == .externalEdit {
            hostNeedsGlobe = needsInputModeSwitchKey
            hostCapitalization = textDocumentProxy.autocapitalizationType ?? .sentences
            switch textDocumentProxy.keyboardType ?? .default {
            case .emailAddress, .URL, .asciiCapable, .asciiCapableNumberPad: hostPrefersEnglish = true
            default: hostPrefersEnglish = false
            }
            switch textDocumentProxy.returnKeyType ?? .default {
            case .send: hostEnterTitle = "发送"
            case .search, .google, .yahoo: hostEnterTitle = "搜索"
            case .go: hostEnterTitle = "前往"
            case .done: hostEnterTitle = "完成"
            case .next: hostEnterTitle = "下一项"
            case .join: hostEnterTitle = "加入"
            default: hostEnterTitle = "换行"
            }
        }
        if case .externalEdit = outcome {
            discardMarkedDelivery()
            surface?.closePanel(); model?.cursorChanged(unmarkDraft: false)
        }
        if case .compositionContextChanged = outcome { model?.refreshCandidates() }
        // A differing snapshot may be an old acknowledgement, but it can also
        // be an external clear that happens to restore an earlier value. Read
        // again after the pending edit lease instead of retaining that stale
        // local text indefinitely. Hosts omitting a live marked range are exempt.
        if case .ownEdit = outcome, hostState.shouldRecheck(actual, now: now) {
            needsHostRefresh = true; scheduleHostRefresh()
        }
    }
    func validateCandidate(before: String, after: String, identity: String) -> Bool {
        guard hostWriteDepth == 0 else { return false }
        // The candidate's generation and local edit snapshot have already been
        // checked. Reading whole remote contexts on touch-up both blocks UIKit
        // and rejects hosts that omit the active marked range from their context.
        guard hostState.snapshot.selected.isEmpty, before == contextBefore, after == contextAfter,
              identity == documentIdentity else { return false }
        let revision = hostRefreshGeneration
        // Do not destroy an active draft on a transient nil response. A real,
        // different UUID still forces the normal external-field reconciliation.
        guard let actualIdentity = connectedDocumentIdentifier()?.uuidString else {
            needsHostRefresh = true; scheduleHostRefresh(); return false
        }
        guard actualIdentity == identity else { refreshHostState(); return false }
        // A selection notification can precede the idle reconciliation. An old
        // candidate must not clear a new selection or insert at a moved caret
        // in the same field. Only this unresolved selection case needs context
        // reads on a tap; ordinary keys/results still do no synchronous reads.
        if candidateSelectionNeedsValidation {
            let actualBefore = textDocumentProxy.documentContextBeforeInput
            let actualAfter = textDocumentProxy.documentContextAfterInput
            let actualSelected = textDocumentProxy.selectedText ?? ""
            let actual = HostTextSnapshot(before: actualBefore ?? "", after: actualAfter ?? "",
                selected: actualSelected, document: actualIdentity,
                available: actualBefore != nil || actualAfter != nil)
            guard revision == hostRefreshGeneration else { return false }
            let wasReadable = readableHostContext
            guard observeContextReadability(actual) else { return false }
            if !wasReadable, actual.available, actualSelected.isEmpty, markedTransport == .local {
                rebaseLocalDraft(on: actual); model?.refreshCandidates()
                return false // The old ribbon describes the previous boundary.
            }
            guard actualSelected.isEmpty,
                  !actual.available || hostState.accepts(hostState.snapshot, actual: actual) else {
                needsHostRefresh = true; scheduleHostRefresh(); return false
            }
            candidateSelectionNeedsValidation = false
        }
        guard revision == hostRefreshGeneration else { return false }
        return hostState.snapshot.selected.isEmpty && before == contextBefore &&
            after == contextAfter && identity == documentIdentity
    }
    private func connectedDocumentIdentifier() -> UUID? {
        // UIKit can return nil before connecting the host, despite its nonoptional Swift UUID declaration.
        // Call the public Objective-C getter so the absent value stays optional during bridging.
        let getter = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard let proxy = textDocumentProxy as? NSObject, proxy.responds(to: getter) else { return nil }
        return proxy.perform(getter)?.takeUnretainedValue() as? UUID
    }
    var contextBefore: String { hostState.snapshot.before }
    var contextAfter: String { hostState.snapshot.after }
    var documentIdentity: String { hostState.snapshot.document }
    var selectedText: String { hostState.snapshot.selected }
    var usesLocalPinyinComposition: Bool {
        if markedTransport != .none { return markedTransport == .local }
        return model?.settings.localPinyinComposition == true || !readableHostContext
    }
    var fullAccess: Bool { hasFullAccess }
    var needsGlobe: Bool { hostNeedsGlobe }
    var capitalization: UITextAutocapitalizationType { hostCapitalization }
    var prefersEnglish: Bool { hostPrefersEnglish }
    var enterTitle: String { hostEnterTitle }
    private func beginHostWrite() {
        hostWriteDepth += 1
        hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil
    }
    private func endHostWrite() {
        hostWriteDepth -= 1
        guard hostWriteDepth == 0 else { return }
        if deferredMarkedFlush {
            deferredMarkedFlush = false
            DispatchQueue.main.async { [weak self] in self?.flushMarkedText() }
        }
        if needsHostRefresh { scheduleHostRefresh() }
    }
    private func performHostEdit(_ edit: () -> Void) {
        // A key arriving before the idle timer fires must cancel that read even
        // if its own textDidChange acknowledgement has not arrived yet.
        beginHostWrite(); defer { endHostWrite() }
        flushMarkedText(insideWrite: true)
        edit()
    }
    func insert(_ text: String) {
        performHostEdit {
            hostState.insert(text)
            markedDraft = ""; markedTransport = .none; sentMarkedDraft = false
            textDocumentProxy.insertText(text)
        }
    }
    func commitMarkedText(_ text: String) {
        commitMarkedText(text, remaining: "")
    }
    @discardableResult func commitMarkedText(_ text: String, remaining: String) -> Bool {
        // Space, punctuation and mode changes can commit without a ribbon tap.
        // Give those entry points the same unresolved-selection protection.
        if candidateSelectionNeedsValidation,
           !validateCandidate(before: contextBefore, after: contextAfter, identity: documentIdentity) {
            abandonDraftWithoutHostWrite()
            return false
        }
        beginHostWrite(); defer { endHostWrite() }
        let originalState = hostState, notifications = hostNotificationRevision
        cancelQueuedMarkedWrites()
        // Clear only the provisional range we actually sent. Buffered editors
        // can otherwise flush its raw pinyin along with insertText's Chinese.
        // unmarkText would commit that pinyin; deleting host text is unsafe.
        let transport = markedTransport == .none ? (usesLocalPinyinComposition ? MarkedTransport.local : .host) : markedTransport
        hostState.commitMarked(text, remaining: remaining)
        markedDraft = remaining
        markedTransport = remaining.isEmpty ? .none : transport
        if sentMarkedDraft {
            sentMarkedDraft = false
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        }
        if !hostActive || (notifications != hostNotificationRevision && !hostStillMatches(originalState, requiresReadable: transport == .host)) {
            // A proxy can service a field switch inside its synchronous call.
            // Neither the old choice nor its remainder belongs to that field;
            // in particular, do not unmark the new field's own provisional text.
            hostState = originalState; abandonDraftWithoutHostWrite()
            needsHostRefresh = true
            return false
        }
        let insertionNotifications = hostNotificationRevision
        textDocumentProxy.insertText(text)
        if !hostActive || (insertionNotifications != hostNotificationRevision && !hostStillMatches(hostState, requiresReadable: transport == .host)) {
            abandonDraftWithoutHostWrite(); needsHostRefresh = true
            return false
        }
        if !remaining.isEmpty, transport == .host { enqueueMarkedText(remaining) }
        return true
    }
    private func hostStillMatches(_ expected: HostTextState, requiresReadable: Bool) -> Bool {
        let revision = hostNotificationRevision
        guard let identity = connectedDocumentIdentifier()?.uuidString,
              identity == expected.snapshot.document else { return false }
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        let selected = textDocumentProxy.selectedText ?? ""
        let actual = HostTextSnapshot(before: before ?? "", after: after ?? "", selected: selected,
            document: identity, available: before != nil || after != nil)
        // Local composition needs only a stable field and no reported selection.
        // A native marked transaction losing its readable context cannot prove
        // that a clear-mark was honoured; abort rather than append a conversion.
        guard revision == hostNotificationRevision else { return false }
        let wasReadable = readableHostContext
        readableHostContext = actual.available
        if !requiresReadable, !wasReadable, actual.available, selected.isEmpty {
            // The client first exposed its real boundary while acknowledging
            // our selected Chinese. Keep the remainder local at that boundary.
            rebaseLocalDraft(on: actual)
            return true
        }
        return selected.isEmpty && ((!actual.available && !requiresReadable) || expected.accepts(expected.snapshot, actual: actual))
    }
    func setMarkedText(_ text: String) {
        hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil
        if markedTransport == .none, !text.isEmpty {
            markedTransport = usesLocalPinyinComposition ? .local : .host
        }
        markedDraft = text
        hostState.setMarked(text)
        if markedTransport == .host { enqueueMarkedText(text) }
        else { cancelQueuedMarkedWrites() }
    }
    private func cancelQueuedMarkedWrites() {
        markedFrame.cancel(); pendingMarkedText.discard()
        markedImmediateScheduled = false; markedWriteGeneration += 1
        deferredMarkedFlush = false
    }
    private func discardMarkedDelivery() {
        cancelQueuedMarkedWrites()
        markedDraft = ""; markedTransport = .none; sentMarkedDraft = false
    }
    private func abandonDraftWithoutHostWrite() {
        hostRefreshGeneration += 1
        discardMarkedDelivery()
        hostState.setMarked(""); hostState.unmark()
        model?.cursorChanged(unmarkDraft: false)
    }
    private func rebaseLocalDraft(on actual: HostTextSnapshot) {
        hostState = HostTextState(actual)
        if !markedDraft.isEmpty { hostState.setMarked(markedDraft) }
    }
    /// Use an already captured snapshot, never another proxy read on a key.
    /// The transport remains local if context becomes available mid-draft.
    private func observeContextReadability(_ actual: HostTextSnapshot) -> Bool {
        readableHostContext = actual.available
        guard actual.document == hostState.snapshot.document, !actual.available,
              markedTransport == .host, !markedDraft.isEmpty else { return true }
        if sentMarkedDraft {
            // The old raw spelling may already be literal in the client. We
            // cannot retract it safely and must not append Chinese after it.
            abandonDraftWithoutHostWrite(); hostState = HostTextState(actual)
            return false
        }
        cancelQueuedMarkedWrites(); markedTransport = .local
        return true
    }
    private func enqueueMarkedText(_ text: String) {
        pendingMarkedText.replace(with: text)
        // UIKit's host proxy crosses a process boundary. Queue turns can run
        // many times before one frame is presented; send the latest spelling
        // once per display opportunity, while keeping the local ledger current.
        guard !markedImmediateScheduled else { return }
        let rate = view.window?.screen.maximumFramesPerSecond ?? 60
        if markedCadence.canWriteImmediately(now: ProcessInfo.processInfo.systemUptime, maximumFramesPerSecond: rate) {
            // Normal single taps retain next-main-turn delivery. Only a burst
            // needs pacing; an idle key must not acquire a full extra frame.
            markedImmediateScheduled = true
            let revision = markedWriteGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.markedWriteGeneration == revision else { return }
                self.flushMarkedText()
                if self.needsHostRefresh { self.scheduleHostRefresh() }
            }
            return
        }
        markedFrame.schedule(in: view, maximumFramesPerSecond: rate) { [weak self] in
            guard let self else { return }
            self.flushMarkedText()
            if self.needsHostRefresh { self.scheduleHostRefresh() }
        }
    }
    private func flushMarkedText(insideWrite: Bool = false) {
        if hostWriteDepth > 0, !insideWrite { deferredMarkedFlush = true; return }
        // Commit, deletion, cursor movement and unmark are ordered barriers.
        // No pending spelling frame may run after those edits.
        markedFrame.cancel()
        markedImmediateScheduled = false; markedWriteGeneration += 1
        guard let text = pendingMarkedText.take() else { return }
        beginHostWrite(); defer { endHostWrite() }
        let event = OSSignpostID(log: hostLog)
        os_signpost(.begin, log: hostLog, name: "MarkedTextWrite", signpostID: event, "utf16=%d", text.utf16.count)
        defer { os_signpost(.end, log: hostLog, name: "MarkedTextWrite", signpostID: event) }
        sentMarkedDraft = !text.isEmpty
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        markedCadence.didWrite(now: ProcessInfo.processInfo.systemUptime)
    }
    func unmarkText() {
        if markedTransport == .local {
            if !markedDraft.isEmpty { commitMarkedText(markedDraft, remaining: "") }
            else { hostState.unmark(); discardMarkedDelivery() }
            return
        }
        performHostEdit {
            hostState.unmark(); markedDraft = ""; markedTransport = .none
            textDocumentProxy.unmarkText(); sentMarkedDraft = false
        }
    }
    func deleteBackward() { performHostEdit { hostState.deleteBackward(); textDocumentProxy.deleteBackward() } }
    func moveCursor(_ offset: Int) {
        performHostEdit { hostState.moveCursor(offset); textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
    }
    func beginTrackpad() { trackpad = ProxyTrackpad(before: contextBefore, after: contextAfter) }
    func trackCursor(translation: CGPoint) {
        guard var state = trackpad else { return }
        let offset = state.offset(translation: translation); trackpad = state
        if offset != 0 { moveCursor(offset) }
    }
    func endTrackpad() { trackpad = nil; refreshHostState() }
    func nextKeyboard() { advanceToNextInputMode() }
    func clearInput() -> DeletedInput? {
        guard hostState.snapshot.document != "disconnected" else { return nil }
        let before = contextBefore, selected = selectedText, after = contextAfter
        let text = before + selected + after
        guard !text.isEmpty, text.count <= 4_096 else { return nil }
        let snapshot = DeletedInput(text: text, selection: NSRange(location: before.utf16.count, length: selected.utf16.count))
        if !selected.isEmpty { insert("") }
        if !after.isEmpty { moveCursor(after.count) }
        for _ in before + after { deleteBackward() }
        return snapshot
    }
    func restoreInput(_ value: DeletedInput) -> Bool {
        guard hostState.snapshot.document != "disconnected" else { return false }
        insert(value.text)
        let prefix = (value.text as NSString).substring(to: min(value.selection.location, value.text.utf16.count))
        moveCursor(prefix.count - value.text.count)
        return true
    }
}

