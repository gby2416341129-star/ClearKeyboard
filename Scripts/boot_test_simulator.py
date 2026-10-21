"""Boot a dedicated test device before compilation, with bounded migration recovery."""
import json,subprocess,uuid
from pathlib import Path

def run(args,**kwargs): return subprocess.run(['xcrun','simctl',*args],**kwargs)
inventory=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j'],text=True))
choices=[]
for runtime,devices in sorted(inventory['devices'].items(),reverse=True):
    if 'iOS' not in runtime:continue
    devices=[d for d in devices if d.get('isAvailable') and 'iPhone' in d['name']]
    if devices:choices.append((runtime,next((d for d in devices if 'Air' in d['name']),devices[0])))
assert choices,'No available iPhone simulator runtime'
selected=[choices[0]]
if len(choices)>1:selected.append(choices[-1])
for runtime,template in selected:
    device_type=template.get('deviceTypeIdentifier')
    if not device_type:
        types=json.loads(subprocess.check_output(['xcrun','simctl','list','devicetypes','-j'],text=True))['devicetypes']
        device_type=next(t['identifier'] for t in types if t['name']==template['name'])
    device=subprocess.check_output(['xcrun','simctl','create','ClearKeyboard CI '+uuid.uuid4().hex[:8],device_type,runtime],text=True).strip()
    uuid.UUID(device)
    for attempt in range(2):
        if attempt:run(['shutdown',device],capture_output=True);run(['erase',device],check=True,capture_output=True)
        run(['boot',device],capture_output=True,timeout=60)
        try:
            result=run(['bootstatus',device,'-b'],capture_output=True,text=True,timeout=150)
            message=result.stdout+result.stderr
            print(message[-2500:],flush=True)
            ok=result.returncode==0 and 'Data Migration Failed' not in message
        except subprocess.TimeoutExpired:
            ok=False
        print('SIMULATOR_BOOT '+json.dumps(dict(runtime=runtime,model=template['name'],attempt=attempt+1,success=ok)),flush=True)
        if ok:
            Path('.build/composition-device-id').write_text(device)
            raise SystemExit(0)
    run(['shutdown',device],capture_output=True)
    run(['delete',device],check=True,capture_output=True)
raise RuntimeError('Dedicated simulator could not complete boot and data migration')
