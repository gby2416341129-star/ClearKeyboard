#!/usr/bin/env python3
"""Final package/identity/linkage checks only. No model or input execution."""
import hashlib,json,plistlib,re,struct,sys,zipfile
BASE='Payload/ClearKeyboard.app/'
EXT=BASE+'PlugIns/ClearKeyboardExtension.appex/'
SHA='d9d1c4974a513236d72f489d0b13f51cb6c7a94b4f2cd5d51400d314dfba80a7'
MODEL='V21PinyinCompactFP16.mlmodelc'
WEIGHTS='4e5849b6efefc351f1c4e39ab2fc0f20ff9d8c16866b3eb2a5b9ed12d0019b98'
def verify(path):
    with zipfile.ZipFile(path) as ipa:
        names=ipa.namelist()
        for prefix,exe in [(BASE,'ClearKeyboard'),(EXT,'ClearKeyboardExtension')]:
            data=ipa.read(prefix+exe)
            assert struct.unpack_from('<II',data)==(0xfeedfacf,0x100000c)
            assert b'v21_decode_path' in data and b'V21IMEKernel' in data,'V21 SDK not linked'
            for old in [b'v19_decode_path',b'V19IMEKernel',b'ck_native_decode',b'ck_qwen_',b'llama_model_load',b'ggml_backend_metal_reg',b'librime',b'ClearV10Scorer',b'ClearV10Model',b'clear-v19-score-domain-stream-2']:
                assert old not in data,'Retired runtime linked: '+str(old)
            info=plistlib.loads(ipa.read(prefix+'Info.plist'))
            assert str(info['CFBundleVersion'])=='94' and info['CFBundleShortVersionString']=='0.1.91'
        assert plistlib.loads(ipa.read(BASE+'Info.plist'))['CFBundleIdentifier']=='com.example.clearkeyboard'
        info=plistlib.loads(ipa.read(EXT+'Info.plist'))
        assert info['CFBundleIdentifier']=='com.example.clearkeyboard.Keyboard'
        assert info['NSExtension']['NSExtensionPointIdentifier']=='com.apple.keyboard-service'
        retired=re.compile(r'qwen|librime|wanxiang|clear[-_]sentence|clearsentence25|llama|ggml|mmproj|(?:^|/)V10(?:/|$)|(?:^|/)V19(?:/|$)|V19FullPinyinFP16|native\.cklx|english\.clx|\.gguf$|\.gram$',re.I)
        for name in names:
            assert not retired.search(name),name
            assert not name.lower().endswith(('.pt','.pth','.onnx','.py','.pyc','.dll','.mlpackage/manifest.json')),name
            assert '/Diagnostics/' not in name and '/Provenance/' not in name and '/BuildAssets/' not in name,name
        roots={n.split('.mlmodelc/')[0]+'.mlmodelc' for n in names if '.mlmodelc/' in n}
        assert roots=={EXT+MODEL},roots
        for name in ['V19Resources.bin','V21Statistics.bin','runtime_config.json','vocabulary.json']:
            assert [n for n in names if n.endswith('/'+name)]==[EXT+'V21/'+name],name
        identity=json.loads(ipa.read(EXT+'V21/identity.json'))
        assert identity['kernel']=='V21' and identity['neural_model']=='V19 best'
        assert identity['checkpoint_sha256']==SHA and identity['step']==38750 and identity['parameters']==20730368
        assert identity['neural_weights_changed'] is False
        assert identity['score_version']=='v21-prior-sequence-energy-1'
        config=json.loads(ipa.read(EXT+'V21/runtime_config.json'))
        assert config['source_checkpoint_sha256']==SHA and config['score_version']==identity['score_version']
        for name in ['V19Resources.bin','V21Statistics.bin','runtime_config.json','vocabulary.json']:
            actual=hashlib.sha256(ipa.read(EXT+'V21/'+name)).hexdigest()
            assert actual==identity['files']['Native/V21NativeIME/Sources/V21NativeIME/Resources/'+name],name
        assert hashlib.sha256(ipa.read(EXT+'V21/V21Statistics.bin')).hexdigest()==config['statistics_sha256']
        assert hashlib.sha256(ipa.read(EXT+MODEL+'/weights/weight.bin')).hexdigest()==WEIGHTS
        manifest=json.loads(ipa.read(EXT+'V21/packaged_manifest.json'))
        assert manifest['kernel']=='V21' and manifest['neural_model']=='V19 best'
        assert 'V21/packaged_manifest.json' not in manifest['files']
        expected={n[len(EXT):] for n in names if n.startswith((EXT+'V21/',EXT+MODEL+'/')) and not n.endswith('/') and n!=EXT+'V21/packaged_manifest.json'}
        assert set(manifest['files'])==expected,'Final manifest coverage mismatch'
        for name,digest in manifest['files'].items():assert hashlib.sha256(ipa.read(EXT+name)).hexdigest()==digest,name
    print('Build94 App/keyboard, V21 identity, unchanged V19 weights, single model and final resource hashes checked.')
if __name__=='__main__':verify(sys.argv[1])
