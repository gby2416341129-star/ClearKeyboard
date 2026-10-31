#!/usr/bin/env python3
"""Final package/identity/linkage checks only. No model or input execution."""
import hashlib,json,plistlib,re,struct,sys,zipfile
BASE='Payload/ClearKeyboard.app/'
EXT=BASE+'PlugIns/ClearKeyboardExtension.appex/'
SHA='d9d1c4974a513236d72f489d0b13f51cb6c7a94b4f2cd5d51400d314dfba80a7'
MODEL='V22PinyinB1FP16.mlmodelc'
WEIGHTS='d5055ba8da86a40c2cb0bba1bebf997141cbd7bed2afeada02c9e11a5d6e585c'
def verify(path):
    with zipfile.ZipFile(path) as ipa:
        names=ipa.namelist()
        for prefix,exe in [(BASE,'ClearKeyboard'),(EXT,'ClearKeyboardExtension')]:
            data=ipa.read(prefix+exe)
            assert struct.unpack_from('<II',data)==(0xfeedfacf,0x100000c)
            assert b'v21_decode_path' in data and b'v21_finish_if_rank_certified' in data and b'V21IMEKernel' in data,'V21 SDK not linked'
            for old in [b'v19_decode_path',b'V19IMEKernel',b'ck_native_decode',b'ck_qwen_',b'llama_model_load',b'ggml_backend_metal_reg',b'librime',b'ClearV10Scorer',b'ClearV10Model',b'clear-v19-score-domain-stream-2']:
                assert old not in data,'Retired runtime linked: '+str(old)
            info=plistlib.loads(ipa.read(prefix+'Info.plist'))
            assert str(info['CFBundleVersion'])=='102' and info['CFBundleShortVersionString']=='0.1.99'
        assert plistlib.loads(ipa.read(BASE+'Info.plist'))['CFBundleIdentifier']=='com.example.clearkeyboard'
        info=plistlib.loads(ipa.read(EXT+'Info.plist'))
        assert info['CFBundleIdentifier']=='com.example.clearkeyboard.Keyboard'
        assert info['NSExtension']['NSExtensionPointIdentifier']=='com.apple.keyboard-service'
        retired=re.compile(r'qwen|librime|wanxiang|clear[-_]sentence|clearsentence25|llama|ggml|mmproj|(?:^|/)V10(?:/|$)|(?:^|/)V19(?:/|$)|V19FullPinyinFP16|native\.cklx|english\.clx|\.gguf$|\.gram$',re.I)
        for name in names:
            assert not retired.search(name),name
            assert not name.lower().endswith(('.pt','.pth','.onnx','.py','.pyc','.dll','.mlpackage/manifest.json')),name
            assert '/Diagnostics/' not in name and '/Provenance/' not in name and '/BuildAssets/' not in name,name
        app_icons={n[len(BASE+'ToolIcons/'):]:hashlib.sha256(ipa.read(n)).hexdigest() for n in names if n.startswith(BASE+'ToolIcons/') and n.endswith('.png')}
        extension_icons={n[len(EXT+'ToolIcons/'):]:hashlib.sha256(ipa.read(n)).hexdigest() for n in names if n.startswith(EXT+'ToolIcons/') and n.endswith('.png')}
        assert app_icons and app_icons==extension_icons,'App/keyboard icon resources differ or are missing'
        roots={n.split('.mlmodelc/')[0]+'.mlmodelc' for n in names if '.mlmodelc/' in n}
        assert roots=={EXT+MODEL},roots
        for name in ['V19Resources.bin','V21Statistics.bin','runtime_config.json','vocabulary.json','V22Language.bin','V22Language.json']:
            assert [n for n in names if n.endswith('/'+name)]==[EXT+'V22/'+name],name
        identity=json.loads(ipa.read(EXT+'V22/identity.json'))
        assert identity['kernel']=='V22' and identity['neural_model']=='V19 best'
        assert identity['checkpoint_sha256']==SHA and identity['step']==38750 and identity['parameters']==20730368
        assert identity['neural_weights_changed'] is False
        assert identity['score_version']=='v21-prior-sequence-energy-1'
        assert identity['sdk_version']=='v22-bounded-native-1' and identity['graph_export_version']=='v22-b1-enumerated-1'
        assert identity['execution_adapter']=='clear-v22-word-reading-3'
        assert not any('V21PinyinCompactFP16' in n or '/V21/' in n for n in names)
        assert hashlib.sha256(ipa.read(EXT+'V22/ordinary_probes_160.json')).hexdigest()==identity['files']['Core/Resources/V22/ordinary_probes_160.json']
        config=json.loads(ipa.read(EXT+'V22/runtime_config.json'))
        assert config['source_checkpoint_sha256']==SHA and config['score_version']==identity['score_version']
        for name in ['V19Resources.bin','V21Statistics.bin','runtime_config.json','vocabulary.json','V22Language.bin','V22Language.json']:
            actual=hashlib.sha256(ipa.read(EXT+'V22/'+name)).hexdigest()
            assert actual==identity['files']['Native/V21NativeIME/Sources/V21NativeIME/Resources/'+name],name
        assert hashlib.sha256(ipa.read(EXT+'V22/V22Language.bin')).hexdigest()==config['language_data_sha256']
        assert config['language_policy_version']=='clear-v22-word-reading-1'
        assert hashlib.sha256(ipa.read(EXT+'V22/V21Statistics.bin')).hexdigest()==config['statistics_sha256']
        assert hashlib.sha256(ipa.read(EXT+MODEL+'/weights/weight.bin')).hexdigest()==WEIGHTS
        manifest=json.loads(ipa.read(EXT+'V22/packaged_manifest.json'))
        assert manifest['kernel']=='V22' and manifest['neural_model']=='V19 best'
        assert 'V22/packaged_manifest.json' not in manifest['files']
        expected={n[len(EXT):] for n in names if n.startswith((EXT+'V22/',EXT+MODEL+'/')) and not n.endswith('/') and n!=EXT+'V22/packaged_manifest.json'}
        assert set(manifest['files'])==expected,'Final manifest coverage mismatch'
        for name,digest in manifest['files'].items():assert hashlib.sha256(ipa.read(EXT+name)).hexdigest()==digest,name
    print('Build102 App/keyboard, V22 identity, inherited V19 weights, single model and final resource hashes checked.')
if __name__=='__main__':verify(sys.argv[1])
