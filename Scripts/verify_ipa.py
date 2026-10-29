#!/usr/bin/env python3
"""Only delivery resource/link/identity checks. Never predict, type or benchmark."""
import hashlib,json,plistlib,struct,sys,zipfile
BASE='Payload/ClearKeyboard.app/'
EXT=BASE+'PlugIns/ClearKeyboardExtension.appex/'
def verify(path):
    with zipfile.ZipFile(path) as ipa:
        names=ipa.namelist()
        for binary in [BASE+'ClearKeyboard',EXT+'ClearKeyboardExtension']:
            data=ipa.read(binary)
            assert struct.unpack_from('<II',data)==(0xfeedfacf,0x100000c),'iPhone arm64 binary required'
            for symbol in [b'ck_qwen_',b'llama_model_load',b'ggml_backend_metal_reg',b'librime']:
                assert symbol not in data,'Old runtime linked: '+str(symbol)
            assert b'ck_native_decode' in data,'Own native engine missing'
        for prefix in [BASE,EXT]:
            info=plistlib.loads(ipa.read(prefix+'Info.plist'))
            assert str(info['CFBundleVersion'])=='85' and 'iPhoneOS' in info['CFBundleSupportedPlatforms']
        assert plistlib.loads(ipa.read(EXT+'Info.plist'))['NSExtension']['NSExtensionPointIdentifier']=='com.apple.keyboard-service'
        for name in names:
            low=name.lower()
            assert not any(old in low for old in ['qwen','rime','wanxiang','.gguf','.gram','clear-sentence','clearsentence25','llama','ggml','mmproj']),name
            assert not low.endswith(('.mlpackage/manifest.json','.pt','.pth','.part','.tar.gz')),name
        compiled=[n for n in names if n.rstrip('/').endswith('.mlmodelc')]
        # ZIP tools may omit directory entries; use the distinct resource root.
        roots={n.split('.mlmodelc/')[0]+'.mlmodelc' for n in names if '.mlmodelc/' in n}
        assert roots=={EXT+'V10/V10KeyboardModel.mlmodelc'},'Model must be packaged once in the keyboard target'
        v10=EXT+'V10/'
        identity=json.loads(ipa.read(v10+'identity.json'))
        assert identity['model_version']=='V10' and identity['delivery_zip_sha256']=='e81300bbe9ceabbc9654b477d797f6e33f778c667e8778ac07affe4c946e4071'
        assert identity['checkpoint_sha256']=='0d27285db15f626a04d37e00070e3c63c803ddb176860be409d069119aca9423'
        compiled_manifest=json.loads(ipa.read(v10+'compiled_manifest.json'))
        for name,digest in compiled_manifest['files'].items():assert hashlib.sha256(ipa.read(v10+name)).hexdigest()==digest,name
        for name in ['vocab.json','calibration.json']:
            assert hashlib.sha256(ipa.read(v10+name)).hexdigest()==identity['runtime_files'][name]
        policy=json.loads(ipa.read(v10+'calibration.json'))
        assert policy['adoption_threshold']==0.65 and not policy['apply_external_affine'] and policy['adoption_logit_is_already_calibrated']
        for name in ['Pinyin/native.cklx','english.clx']:
            assert BASE+name in names and EXT+name not in names
        with ipa.open(BASE+'Pinyin/native.cklx') as stream:header=stream.read(64)
        assert header[:8]==b'CKLX85\0\0' and struct.unpack_from('<I',header,8)[0]==4
    print('Build 85 iPhone binaries, single V10 identity, native index and old-runtime removal checked.')
if __name__=='__main__':verify(sys.argv[1])
