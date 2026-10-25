"""Scoped keyboard repair: decoder/model unchanged; edit ledger is re-tested."""
import json,subprocess
BASE='fed2ef08404cd5b0f252a798922e884d4868655b'
ALLOWED={
    'SharedUI/BrandMaterial.swift','Scripts/prepare_app_icon.swift','Scripts/build-ipa.sh','App/ClearAppIcon.icon/icon.json',
    'App/AppDesign.swift','SharedUI/LiquidGlass.swift','SharedUI/ValueSlider.swift','SharedUI/ToolArtwork.swift',
    'SharedUI/Resources/BrandMark.png','App/Assets.xcassets/AppIcon.appiconset/AppIcon.png',
    'Scripts/generate_project.py','NativeTests/GlassDesignRuntimeTests.swift',
    '.github/workflows/ipa.yml','Scripts/verify_ui_hotfix.py',
    'Scripts/boot_test_simulator.py','Scripts/test-composition-proxy.sh',
    'App/AppViews.swift','App/SettingsViews.swift',
    'Config/Project.xcconfig','KeyboardExtension/KeyboardViewController.swift',
    'SharedUI/AppearanceEditor.swift','SharedUI/GlassBackdrop.swift','SharedUI/KeyButton.swift',
    'Scripts/test-candidates-ui.sh','Scripts/test-key-material.sh',
    'ClearKeyboard.xcodeproj/project.pbxproj',
    'Tests/CandidateLatencyTests.swift',
    'SharedUI/KeyboardModel.swift','SharedUI/AppearanceSync.swift','SharedUI/AppearanceSettingsLink.swift',
    'SharedUI/CandidateScrollView.swift','SharedUI/KeyboardSurface.swift','SharedUI/ClipboardPanel.swift',
    'SharedUI/KeyboardAppearancePreview.swift','SharedUI/SharedStorage.swift',
    'NativeTests/UnifiedRepairTests.swift','NativeTests/CustomizationRuntimeTests.swift',
    'UITests/AppUITests.swift','NativeTests/AppearanceSyncRuntimeTests.swift','NativeTests/AppearanceReceiverRuntimeTests.swift',
    'NativeTests/KeyboardRuntimeTests.swift','NativeTests/RemoteProxyPerformanceTests.swift','NativeTests/CandidateAnimationRuntimeTests.swift',
    'SharedUI/ClipboardCapture.swift','NativeTests/ClipboardCaptureRepairTests.swift',
    'Core/HostTextState.swift','Tests/HostTextStateTests.swift','Core/Settings.swift','Tests/StateTests.swift',
    'Core/KeyboardLayout.swift','Core/KeyAlternatives.swift','SharedUI/CenteredKeyLabel.swift',
    'SharedUI/KeyChoicePopup.swift','SharedUI/KeyboardAppearancePanelView.swift','NativeTests/CurrentRoundRepairTests.swift',
    'Config/App.entitlements','Config/Keyboard.entitlements','Config/App-Info.plist','Config/Keyboard-Info.plist',
    'Scripts/test-current-round-ui.sh',
    'NativeTests/ToolbarRuntimeTests.swift','UITests/KeyboardShellUITests.swift',
    'Scripts/setup_keyboard_shell_sim.py','Scripts/test-keyboard-shell.sh',
}
changed=set(subprocess.check_output(['git','diff','--name-only',BASE,'HEAD'],text=True).splitlines())
ALLOWED.update("SharedUI/Resources/ToolGlass/" + p for p in [
    'tool-appearance.png','tool-clipboard.png','tool-compatibility.png','tool-emoji.png','tool-key-color.png','tool-key-glass.png','tool-language.png','tool-license.png','tool-phonetic.png','tool-privacy.png','tool-settings.png','tool-single-hand.png','tool-text-color.png','tool-text-size.png','tool-toolbar.png'
])
ALLOWED.update(p for p in changed if p.startswith(("SharedUI/Resources/ToolIcons/", "Design/SelectedIcons/", "Design/SoftGlass58/")))
assert changed and changed<=ALLOWED,sorted(changed-ALLOWED)
subprocess.run(['git','diff','--exit-code',BASE,'HEAD','--','Core',':(exclude)Core/HostTextState.swift',':(exclude)Core/Settings.swift',':(exclude)Core/KeyboardLayout.swift',':(exclude)Core/KeyAlternatives.swift',
    'CRime','Data','Tests/Evaluation','Licenses'],check=True)
print('UI_HOTFIX_SCOPE '+json.dumps(dict(status='passed',baselineCommit=BASE,baselineRun=39594324975,
    modelAndDecoderSourcesUnchanged=True,editLedgerChanged='Core/HostTextState.swift' in changed,
    keyboardSettingsChanged='Core/Settings.swift' in changed,
    requiresFullCoreTests=True,keyboardInteractionMayChange=True,changedFiles=sorted(changed)),ensure_ascii=False))
