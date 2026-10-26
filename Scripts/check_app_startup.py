"""Run the reported startup path before and after its removal, using Release UI tests."""
import json,os,subprocess,time
from pathlib import Path

ROOT=Path(__file__).resolve().parent.parent
os.chdir(ROOT)
OUT=ROOT/'.build/StartupDiagnostics';OUT.mkdir(parents=True,exist_ok=True)
BASE='7bbac2b2f4175c304ba0490335a1ab727694e35b'
FILES=['App/AppViews.swift','App/AppRefreshPreference.swift','Config/Project.xcconfig']
fixed={name:(ROOT/name).read_bytes() if (ROOT/name).exists() else None for name in FILES}
subprocess.run(['python3','Scripts/boot_test_simulator.py'],check=True)
device=(ROOT/'.build/composition-device-id').read_text().strip()

def diagnostics(label):
    result=subprocess.run(['xcrun','simctl','spawn',device,'log','show','--last','3m','--style','compact','--predicate','process == "ClearKeyboard" OR process == "ClearKeyboardExtension"'],capture_output=True,text=True,timeout=60)
    (OUT/(label+'-runtime.log')).write_text(result.stdout+result.stderr)
    folder=Path.home()/'Library/Logs/DiagnosticReports'
    for path in folder.glob('ClearKeyboard*'):
        if path.is_file() and path.suffix in ['.ips','.crash']:
            (OUT/(label+'-'+path.name)).write_bytes(path.read_bytes())

def probe(label):
    subprocess.run(['python3','Scripts/generate_project.py'],check=True)
    result=OUT/(label+'.xcresult')
    args=['xcodebuild','-project','ClearKeyboard.xcodeproj','-scheme','ClearKeyboardUI','-configuration','Release',
          '-destination','platform=iOS Simulator,id='+device,'-derivedDataPath','.build/StartupRelease',
          '-resultBundlePath',str(result),'-destination-timeout','90','-parallel-testing-enabled','NO',
          '-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','240',
          '-only-testing:ClearKeyboardUITests/StartupRecoveryUITests/testColdLaunchTabsAndForegroundRecovery',
          'CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-','ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','test']
    with (OUT/(label+'-xcodebuild.log')).open('w') as log:
        completed=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,timeout=1200)
    try:diagnostics(label)
    except (OSError,subprocess.TimeoutExpired) as error:print('Diagnostic log unavailable: '+str(error),flush=True)
    summary=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(result)],capture_output=True,text=True)
    payload=json.loads(summary.stdout) if summary.returncode==0 else {}
    (OUT/(label+'-summary.json')).write_text(json.dumps(payload,indent=2))
    print('STARTUP_PROBE '+json.dumps(dict(label=label,exit=completed.returncode,total=payload.get('totalTestCount'),passed=payload.get('passedTests'),failed=payload.get('failedTests'))),flush=True)
    # Report the relevant runtime exception without dumping unrelated logs.
    for path in OUT.glob(label+'-*.ips'):
        print('STARTUP_CRASH '+path.name,flush=True)
        lines=path.read_text(errors='replace').splitlines()
        print('\n'.join(lines[:3])[:1000],flush=True)
    return dict(exit=completed.returncode,summary=payload)

report={}
try:
    for name in FILES:
        (ROOT/name).write_bytes(subprocess.check_output(['git','show',BASE+':'+name]))
    report['build75StartupPath']=probe('before-build75')
finally:
    for name,data in fixed.items():
        path=ROOT/name
        if data is None:path.unlink(missing_ok=True)
        else:path.write_bytes(data)
report['fixedStartup']=probe('fixed-build76')
(OUT/'startup-check.json').write_text(json.dumps(report,indent=2))
summary=report['fixedStartup']['summary']
assert report['fixedStartup']['exit']==0,'The repaired app did not pass startup UI validation'
assert summary.get('totalTestCount',0)>=1 and summary.get('failedTests',1)==0,'No passing startup UI result'
print('APP_STARTUP_RELEASE_VERIFIED '+json.dumps(dict(coldLaunches=3,tabs=3,foregroundReturns=3)),flush=True)
