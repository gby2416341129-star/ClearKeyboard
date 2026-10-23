"""Scoped keyboard repair: decoder/model unchanged; edit ledger is re-tested."""
import json,subprocess
BASE='fed2ef08404cd5b0f252a798922e884d4868655b'
ALLOWED={
    '.github/workflows/ipa.yml','Scripts/verify_ui_hotfix.py',
    'Scripts/boot_test_simulator.py','Scripts/test-composition-proxy.sh',
    'App/AppViews.swift','App/SettingsViews.swift',
    'Config/Project.xcconfig','KeyboardExtension/KeyboardViewController.swift',
    'SharedUI/AppearanceEditor.swift','SharedUI/GlassBackdrop.swift','SharedUI/KeyButton.swift',
    'Scripts/test-candidates-ui.sh',
    'ClearKeyboard.xcodeproj/project.pbxproj',
    'SharedUI/KeyboardModel.swift','SharedUI/AppearanceSync.swift','SharedUI/AppearanceSettingsLink.swift',
    'SharedUI/CandidateScrollView.swift','SharedUI/KeyboardSurface.swift','SharedUI/ClipboardPanel.swift',
    'SharedUI/KeyboardAppearancePreview.swift','SharedUI/SharedStorage.swift',
    'NativeTests/UnifiedRepairTests.swift','NativeTests/CustomizationRuntimeTests.swift',
    'UITests/AppUITests.swift','NativeTests/AppearanceSyncRuntimeTests.swift','NativeTests/AppearanceReceiverRuntimeTests.swift',
    'NativeTests/KeyboardRuntimeTests.swift','NativeTests/RemoteProxyPerformanceTests.swift','NativeTests/CandidateAnimationRuntimeTests.swift',
    'Core/HostTextState.swift','Tests/HostTextStateTests.swift','Core/Settings.swift','Tests/StateTests.swift',
    'NativeTests/ToolbarRuntimeTests.swift','UITests/KeyboardShellUITests.swift',
    'Scripts/setup_keyboard_shell_sim.py','Scripts/test-keyboard-shell.sh',
}
changed=set(subprocess.check_output(['git','diff','--name-only',BASE,'HEAD'],text=True).splitlines())
assert changed and changed<=ALLOWED,sorted(changed-ALLOWED)
subprocess.run(['git','diff','--exit-code',BASE,'HEAD','--','Core',':(exclude)Core/HostTextState.swift',':(exclude)Core/Settings.swift',
    'CRime','Data','Tests/Evaluation','Licenses'],check=True)
print('UI_HOTFIX_SCOPE '+json.dumps(dict(status='passed',baselineCommit=BASE,baselineRun=39594324975,
    modelAndDecoderSourcesUnchanged=True,editLedgerChanged='Core/HostTextState.swift' in changed,
    keyboardSettingsChanged='Core/Settings.swift' in changed,
    requiresFullCoreTests=True,keyboardInteractionMayChange=True,changedFiles=sorted(changed)),ensure_ascii=False))
