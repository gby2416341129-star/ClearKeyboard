"""UI-only release gate: reuse build48 model evidence only if input code is identical."""
import json,subprocess
BASE='fed2ef08404cd5b0f252a798922e884d4868655b'
ALLOWED={
    '.github/workflows/ipa.yml','Scripts/verify_ui_hotfix.py',
    'Scripts/boot_test_simulator.py','Scripts/test-composition-proxy.sh',
    'App/AppViews.swift','App/SettingsViews.swift',
    'SharedUI/AppearanceEditor.swift','SharedUI/GlassBackdrop.swift',
    'SharedUI/KeyboardAppearancePreview.swift','SharedUI/SharedStorage.swift',
    'NativeTests/UnifiedRepairTests.swift','NativeTests/CustomizationRuntimeTests.swift',
    'UITests/AppUITests.swift',
}
changed=set(subprocess.check_output(['git','diff','--name-only',BASE,'HEAD'],text=True).splitlines())
assert changed and changed<=ALLOWED,sorted(changed-ALLOWED)
subprocess.run(['git','diff','--exit-code',BASE,'HEAD','--','Core','CRime','Data','Tests/Evaluation','Licenses'],check=True)
print('UI_HOTFIX_SCOPE '+json.dumps(dict(status='passed',baselineCommit=BASE,baselineRun=39594324975,
    modelAndInputSourcesUnchanged=True,changedFiles=sorted(changed)),ensure_ascii=False))
