from pathlib import Path
import json,hashlib,plistlib,zipfile,shutil
root=Path(__file__).resolve().parents[1]
bundle=root/'work/build/Build/Products/Release-iphoneos/V49Probe.app'
artifact=root/'work/artifacts'
identity=json.loads((root/'Assets/model_identity.json').read_text())
compiled=[]
for model in ['V49PinyinANE64FP16','V49InputSequenceFP16']:
 directory=bundle/(model+'.mlmodelc')
 assert directory.is_dir(),model
 for p in sorted(directory.rglob('*')):
  if p.is_file():compiled.append({'path':p.relative_to(bundle).as_posix(),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
assert not list(bundle.rglob('*.pt')) and not list(bundle.rglob('*.npz')) and not list(bundle.rglob('*.mlpackage'))
(bundle/'Assets/compiled_model_manifest.json').write_text(json.dumps({'files':compiled},indent=2))
resources=[]
for p in sorted((bundle/'Assets').rglob('*')):
 if p.is_file():resources.append({'path':p.relative_to(bundle).as_posix(),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
info=plistlib.loads((bundle/'Info.plist').read_bytes())
manifest={'bundle_id':info['CFBundleIdentifier'],'build':info['CFBundleVersion'],'model':'V49','local_step':1408,'global_step':94661,'source_checkpoint_sha256':identity['source']['checkpoint_sha256'],'parameters':21020402,'graph_revision':'v49-static64-bc1s-2','weights_changed_in_this_revision':False,'training_started':False,'compiled_models':compiled,'resources':resources,'inference_executed':False,'tests_executed':False,'user_runs_all_tests':True,'keyboard_project_modified':False,'research_only':True,'quality_passed':False,'deployment_ready':False}
(artifact/'build_manifest.json').write_text(json.dumps(manifest,indent=2))
ipa=artifact/'V49Probe-build2-ANE-unsigned.ipa'
with zipfile.ZipFile(ipa,'w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted(bundle.rglob('*')):
  if p.is_file():z.write(p,'Payload/V49Probe.app/'+p.relative_to(bundle).as_posix())
(artifact/(ipa.name+'.sha256')).write_text(hashlib.sha256(ipa.read_bytes()).hexdigest()+'  '+ipa.name+'\n')
with zipfile.ZipFile(artifact/'V49_CoreML_FP16_step1408_ANE2.zip','w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted((root/'Model').rglob('*')):
  if p.is_file():z.write(p,p.relative_to(root).as_posix())
 for name in ['source.json','compact_export_record.json','aux_export_record.json']:
  z.write(root/'Export'/name,'Provenance/'+name)
(artifact/'STATUS.txt').write_text('Converted exact V49 weights, compiled and packaged. No model predictions or tests executed. User measures on iPhone.\n')
print(json.dumps({'ipa':str(ipa),'bytes':ipa.stat().st_size,'sha256':hashlib.sha256(ipa.read_bytes()).hexdigest()}))
