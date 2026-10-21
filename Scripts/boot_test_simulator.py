"""Start a preinstalled simulator and prove UI services are ready before tests."""
import json,os,subprocess,sys,uuid
from pathlib import Path

def run(args,timeout=30):
    try:return subprocess.run(['xcrun','simctl',*args],capture_output=True,text=True,timeout=timeout)
    except subprocess.TimeoutExpired:return None

device_file=Path('.build/composition-device-id')
if '--cleanup' in sys.argv:
    if device_file.is_file():
        device=device_file.read_text().strip();uuid.UUID(device)
        run(['shutdown',device],timeout=20)
    raise SystemExit(0)

Path('.build').mkdir(exist_ok=True)
def inventory_json(args):
    # CoreSimulator's first connection on a fresh hosted VM can outlast one
    # short probe. Retry that read without erasing devices or relaxing readiness.
    for attempt in range(3):
        result=run(args,timeout=45)
        if result and result.returncode==0:
            try:return json.loads(result.stdout)
            except json.JSONDecodeError:pass
        print('SIMULATOR_INVENTORY_RETRY '+json.dumps(dict(attempt=attempt+1,
            detail=(result.stderr[-700:] if result else 'service connection timed out'))),flush=True)
    raise RuntimeError('CoreSimulator inventory did not become available')
inventory=inventory_json(['list','devices','available','-j'])
runtimes=inventory_json(['list','runtimes','-j'])
versions={entry['identifier']:entry['version'] for entry in runtimes['runtimes']}
choices=[]
for runtime,devices in sorted(inventory['devices'].items(),reverse=True):
    if 'iOS' not in runtime:continue
    devices=[d for d in devices if d.get('isAvailable') and 'iPhone' in d['name']]
    if devices:choices.append((runtime,next((d for d in devices if 'Air' in d['name']),devices[0])))
assert choices,'No available iPhone simulator runtime'
preferred=os.environ.get('CLEAR_TEST_SIMULATOR_RUNTIME','')
required_major=os.environ.get('CLEAR_TEST_REQUIRED_RUNTIME_MAJOR','')
if required_major:
    prefix='com.apple.CoreSimulator.SimRuntime.iOS-'+str(int(required_major))
    choices=[choice for choice in choices if choice[0]==prefix or choice[0].startswith(prefix+'-')]
    assert choices,'The required iOS major runtime is unavailable: '+required_major
elif os.environ.get('CLEAR_TEST_REQUIRE_RUNTIME')=='1':
    assert preferred,'A required simulator runtime must be specified'
    choices=[choice for choice in choices if choice[0]==preferred]
    assert choices,'The required simulator runtime is unavailable: '+preferred
if preferred:choices.sort(key=lambda choice: choice[0]!=preferred)
if device_file.is_file():
    selected=device_file.read_text().strip();uuid.UUID(selected)
    choices.sort(key=lambda choice: choice[1]['udid']!=selected)
print('SIMULATOR_CANDIDATES '+json.dumps([dict(runtime=r,model=d['name']) for r,d in choices[:2]]),flush=True)

def ready(device):
    board=run(['spawn',device,'launchctl','print','system/com.apple.SpringBoard'],timeout=20)
    springboard=bool(board and board.returncode==0 and 'state = running' in board.stdout)
    listed=run(['listapps',device],timeout=20)
    apps={}
    if listed and listed.returncode==0:
        # simctl emits an OpenStep plist on some Xcode versions. Apple's plist
        # converter handles that format as well as XML, binary plists and JSON.
        try:
            converted=subprocess.run(['/usr/bin/plutil','-convert','json','-o','-','--','-'],
                input=listed.stdout,capture_output=True,text=True,timeout=20)
            if converted.returncode==0:apps=json.loads(converted.stdout)
            else:print('App plist conversion: '+converted.stderr[-700:],flush=True)
        except (subprocess.TimeoutExpired,json.JSONDecodeError):
            print('App plist conversion did not complete',flush=True)
    screenshot=Path('.build/simulator-readiness-'+device+'.png')
    captured=run(['io',device,'screenshot',str(screenshot)],timeout=20)
    image_ok=bool(captured and captured.returncode==0 and screenshot.is_file() and screenshot.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
    result=dict(springboardRunning=springboard,preferencesInstalled='com.apple.Preferences' in apps,screenshotRendered=image_ok)
    print('SIMULATOR_READINESS '+json.dumps(result),flush=True)
    if not all(result.values()):
        for name,probe in [('SpringBoard',board),('App service',listed),('Screen render',captured)]:
            if probe is None or probe.returncode!=0:
                print(name+': '+((probe.stderr or probe.stdout)[-700:] if probe else 'probe timed out'),flush=True)
    return all(result.values())

developer=os.environ.get('DEVELOPER_DIR','')
simulator=Path(developer)/'Applications/Simulator.app'
for runtime,template in choices[:2]:
    # Each hosted job starts in its own disposable VM. Use the image's existing
    # profile instead of repeatedly creating and erasing incomplete migrations.
    device=template['udid'];uuid.UUID(device)
    if simulator.is_dir():
        try:subprocess.run(['open','-g','-a',str(simulator),'--args','-CurrentDeviceUDID',device],capture_output=True,timeout=20)
        except subprocess.TimeoutExpired:print('Simulator UI launch timed out; checking its services directly',flush=True)
    run(['boot',device],timeout=60)
    warning=False
    for attempt in range(2):
        result=run(['bootstatus',device,'-b'],timeout=180)
        message=(result.stdout+result.stderr) if result else 'Boot status timed out'
        print(message[-3500:],flush=True)
        migrated=bool(result and result.returncode==0 and 'Data Migration Failed' not in message)
        warning=warning or not migrated
        healthy=ready(device)
        print('SIMULATOR_BOOT '+json.dumps(dict(runtime=runtime,osVersion=versions.get(runtime),model=template['name'],
            attempt=attempt+1,success=healthy,migrationWarningObserved=warning,profile='preinstalled',uiReadinessChecked=True)),flush=True)
        if healthy:
            device_file.write_text(device)
            raise SystemExit(0)
        # A system migration warning is distinct from a working UI service.
        # Keep the partial migration, then repeat bounded readiness probes.
    diagnostics=run(['spawn',device,'log','show','--last','2m','--style','compact','--predicate',
        'process == "datamigrator" OR process == "migrationpluginwrapper"'],timeout=20)
    if diagnostics:print((diagnostics.stdout+diagnostics.stderr)[-10000:],flush=True)
    run(['shutdown',device],timeout=20)
raise RuntimeError('No required simulator completed the SpringBoard, app-service and render readiness checks')
