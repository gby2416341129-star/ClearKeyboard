#!/usr/bin/env python3
"""Final resource, identity and linkage checks only. No model/input execution."""
import hashlib,json,plistlib,re,struct,sys,zipfile
BASE='Payload/ClearKeyboard.app/'
EXT=BASE+'PlugIns/ClearKeyboardExtension.appex/'
SHA='d9d1c4974a513236d72f489d0b13f51cb6c7a94b4f2cd5d51400d314dfba80a7'
def verify(path):
    with zipfile.ZipFile(path) as ipa:
        names=ipa.namelist()
        for prefix,exe in [(BASE,'ClearKeyboard'),(EXT,'ClearKeyboardExtension')]:
            data=ipa.read(prefix+exe)
            assert struct.unpack_from('<II',data)==(0xfeedfacf,0x100000c)
            assert b'v19_decode_path' in data and b'V19IMEKernel' in data,'V19 native SDK must be linked'
            for old in [b'ck_native_decode',b'ck_qwen_',b'llama_model_load',b'ggml_backend_metal_reg',b'librime',b'ClearV10Scorer',b'ClearV10Model']:
                assert old not in data,'Old runtime linked: '+str(old)
            info=plistlib.loads(ipa.read(prefix+'Info.plist'))
            assert str(info['CFBundleVersion'])=='92' and info['CFBundleShortVersionString']=='0.1.89'
        assert plistlib.loads(ipa.read(EXT+'Info.plist'))['NSExtension']['NSExtensionPointIdentifier']=='com.apple.keyboard-service'
        old=re.compile(r'qwen|librime|wanxiang|clear[-_]sentence|clearsentence25|llama|ggml|mmproj|(?:^|/)V10(?:/|$)|native\.cklx|english\.clx|\.gguf$|\.gram$',re.I)
        for n in names:
            assert not old.search(n),n
            assert not n.lower().endswith(('.pt','.pth','.onnx','.py','.pyc','.mlpackage/manifest.json')),n
        roots={n.split('.mlmodelc/')[0]+'.mlmodelc' for n in names if '.mlmodelc/' in n}
        assert roots=={EXT+'V19FullPinyinFP16.mlmodelc'},roots
        assert [n for n in names if n.endswith('/V19Resources.bin')]==[EXT+'V19/V19Resources.bin']
        identity=json.loads(ipa.read(EXT+'V19/identity.json'))
        assert identity['sdk_patch']['revision']=='clear-v19-score-domain-stream-2'
        assert identity['checkpoint_sha256']==SHA and identity['step']==38750 and identity['parameters']==20730368
        config=ipa.read(EXT+'V19/runtime_config.json')
        assert hashlib.sha256(config).hexdigest()==identity['files']['Native/V19NativeIME/Sources/V19NativeIME/Resources/runtime_config.json']
        assert hashlib.sha256(ipa.read(EXT+'V19/V19Resources.bin')).hexdigest()==json.loads(config)['resource_binary_sha256']
        manifest=json.loads(ipa.read(EXT+'V19/packaged_manifest.json'))
        assert 'V19/packaged_manifest.json' not in manifest['files']
        expected={n[len(EXT):] for n in names if n.startswith((EXT+'V19/',EXT+'V19FullPinyinFP16.mlmodelc/')) and not n.endswith('/') and n!=EXT+'V19/packaged_manifest.json'}
        assert set(manifest['files'])==expected,'Final manifest coverage mismatch'
        for n,h in manifest['files'].items():assert hashlib.sha256(ipa.read(EXT+n)).hexdigest()==h,n
    print('Build92 App/keyboard, versioned V19 identity, single model and final resource hashes checked.')
if __name__=='__main__':verify(sys.argv[1])
