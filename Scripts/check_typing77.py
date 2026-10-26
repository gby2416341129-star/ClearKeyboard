"""Focused Release checks for caret delivery, fast key feedback, and all-fuzzy typing."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
OUT = ROOT / '.build/Typing77'
OUT.mkdir(parents=True, exist_ok=True)
subprocess.run(['swiftc', 'SharedUI/BrandMaterial.swift', 'Scripts/prepare_app_icon.swift', '-o', '.build/typing77-app-icon'], check=True)
subprocess.run(['.build/typing77-app-icon'], check=True)
subprocess.run(['python3', 'Scripts/generate_project.py'], check=True)
subprocess.run(['python3', 'Scripts/boot_test_simulator.py'], check=True)
device = (ROOT / '.build/composition-device-id').read_text().strip()
report = {}
for name, scheme, targets, expected in [
    ('runtime', 'ClearKeyboardRuntime', ['ClearKeyboardRuntimeTests/Typing77Tests'], 8),
    ('startup', 'ClearKeyboardUI', ['ClearKeyboardUITests/StartupRecoveryUITests/testColdLaunchTabsAndForegroundRecovery'], 1),
]:
    bundle = OUT / (name + '.xcresult')
    command = ['xcodebuild', '-quiet', '-project', 'ClearKeyboard.xcodeproj', '-scheme', scheme,
               '-configuration', 'Release', '-destination', 'platform=iOS Simulator,id=' + device,
               '-derivedDataPath', '.build/Typing77Release', '-resultBundlePath', str(bundle),
               '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
               '-maximum-test-execution-time-allowance', '180', 'CODE_SIGNING_ALLOWED=YES',
               'CODE_SIGN_IDENTITY=-', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES']
    command += ['-only-testing:' + value for value in targets] + ['test']
    with (OUT / (name + '-xcodebuild.log')).open('w') as log:
        run = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
    metadata = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)], capture_output=True, text=True)
    summary = json.loads(metadata.stdout) if metadata.returncode == 0 else {}
    (OUT / (name + '-summary.json')).write_text(json.dumps(summary, indent=2))
    tests = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(bundle)], capture_output=True, text=True)
    (OUT / (name + '-tests.json')).write_text(tests.stdout)
    report[name] = dict(exit=run.returncode, summary=summary)
    (OUT / 'checks.json').write_text(json.dumps(report, indent=2))
    print('TYPING77_CHECK ' + json.dumps(dict(check=name, exit=run.returncode, passed=summary.get('passedTests'), failed=summary.get('failedTests'))), flush=True)
    if run.returncode:
        print((OUT / (name + '-xcodebuild.log')).read_text(errors='replace')[-10000:], flush=True)
    assert run.returncode == 0, name + ' check failed'
    assert summary.get('passedTests') == expected and summary.get('failedTests') == 0 and summary.get('skippedTests', 0) == 0, summary
print('TYPING77_RELEASE_CHECKS_PASSED runtime=8 startup=1 physicalFeelUnmeasured=true', flush=True)
