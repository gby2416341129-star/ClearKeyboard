#!/usr/bin/env python3
"""Check compiled artifact identity, linkage and bytes. Never run model/tests."""
import hashlib,json,plistlib,struct,sys,zipfile
from pathlib import Path

BASE='Payload/ClearKeyboard.app/'
EXT=BASE+'PlugIns/ClearKeyboardExtension.appex/'
CHECKPOINT='6b2a81977f112ebdc1763198dac5e7e68caeef0d4d65fc7819ec3133e5929f58'
MODELS=['V49PinyinB1FP16.mlmodelc','V49InputSequenceFP16.mlmodelc']
DATA=['V19Resources.bin','V21Statistics.bin','V22Language.bin','vocabulary.json','V22Language.json','runtime_config.json']

def verify(path):
    with zipfile.ZipFile(path) as ipa:
        names=ipa.namelist()
        for prefix,executable in [(BASE,'ClearKeyboard'),(EXT,'ClearKeyboardExtension')]:
            data=ipa.read(prefix+executable)
            assert struct.unpack_from('<II',data)==(0xfeedfacf,0x100000c)
            for symbol in [b'v21_decode_path',b'v23_configure_request',b'v24_apply_scores',b'V21IMEKernel']:
                assert symbol in data,'Paired V49 SDK not linked: '+str(symbol)
            info=plistlib.loads(ipa.read(prefix+'Info.plist'))
            assert str(info['CFBundleVersion'])=='109' and info['CFBundleShortVersionString']=='0.1.106'
        assert plistlib.loads(ipa.read(BASE+'Info.plist'))['CFBundleIdentifier']=='com.example.clearkeyboard'
        ext_info=plistlib.loads(ipa.read(EXT+'Info.plist'))
        assert ext_info['CFBundleIdentifier']=='com.example.clearkeyboard.Keyboard'
        assert ext_info['NSExtension']['NSExtensionPointIdentifier']=='com.apple.keyboard-service'
        roots={n.split('.mlmodelc/')[0]+'.mlmodelc' for n in names if '.mlmodelc/' in n}
        assert roots=={EXT+name for name in MODELS},roots
        assert not any(n.lower().endswith(('.pt','.pth','.npz','.onnx','.py','.pyc','.dll','.mlpackage/manifest.json')) for n in names)
        assert not any('/BuildAssets/' in n or '/Provenance/' in n or '/Diagnostics/' in n for n in names)
        for name in DATA:
            assert [n for n in names if n.endswith('/'+name)]==[EXT+'V49/'+name],name
        identity=json.loads(ipa.read(EXT+'V49/identity.json'))
        assert identity['checkpoint_sha256']==CHECKPOINT
        assert (identity['local_step'],identity['global_step'],identity['parameters'])==(1408,94661,21020402)
        assert identity['compute_units']=='cpuOnly' and identity['fallback_to_other_compute_units'] is False
        config=json.loads(ipa.read(EXT+'V49/runtime_config.json'))
        assert config['source_checkpoint_sha256']==CHECKPOINT and config['source_step']==94661
        assert config['score_version']==identity['score_version']=='v23-input-sequence-energy-1'
        assert config['ranking_policy_version']==identity['ranking_policy_version']=='build109-word-initials-recall-1'
        assert identity['maximum_visible_candidates']==config['topk']==64
        english_names=['words.txt','manifest.json','SOURCE-NOTICE.txt','AGID-LICENSE.txt']
        for name in english_names:
            assert [n for n in names if n.endswith('/EnglishWords/'+name)]==[EXT+'EnglishWords/'+name],name
            assert hashlib.sha256(ipa.read(EXT+'EnglishWords/'+name)).hexdigest()==identity['files']['Core/Resources/EnglishWords/'+name],name
        emoticons=json.loads(ipa.read(EXT+'Emoticons/manifest.json'))
        catalog=json.loads(ipa.read(EXT+'Emoticons/catalog.json'))
        assert len(catalog['entries'])==emoticons['total_entries']==106
        assert emoticons['wechat_codes']==106 and emoticons['real_image_regions']==106
        assert all(entry['kind']=='wechat' for entry in catalog['entries'])
        assert len({entry['code'] for entry in catalog['entries']})==106
        assert emoticons['complete_current_wechat_claim'] is False
        for name,record in emoticons['files'].items():
            payload=ipa.read(EXT+'Emoticons/'+name)
            assert len(payload)==record['bytes'] and hashlib.sha256(payload).hexdigest()==record['sha256'],name
        actual_emoticons={n[len(EXT+'Emoticons/'):] for n in names if n.startswith(EXT+'Emoticons/') and not n.endswith('/')}
        assert actual_emoticons==set(emoticons['files'])|{'manifest.json'},'Unexpected emoticon resources'
        assert not any(n.startswith(BASE+'Emoticons/') for n in names),'Keep a single copy in the keyboard bundle'
        prefix='Native/V21NativeIME/Sources/V21NativeIME/Resources/'
        for name in DATA:
            assert hashlib.sha256(ipa.read(EXT+'V49/'+name)).hexdigest()==identity['files'][prefix+name],name
        for model in MODELS:
            source='Core/Resources/V49/'+model.replace('.mlmodelc','.mlpackage')+'/Data/com.apple.CoreML/weights/weight.bin'
            assert hashlib.sha256(ipa.read(EXT+model+'/weights/weight.bin')).hexdigest()==identity['files'][source],model
        assert hashlib.sha256(ipa.read(EXT+'V49/ordinary_probes_160.json')).hexdigest()==identity['files']['Core/Resources/V49/ordinary_probes_160.json']
        manifest=json.loads(ipa.read(EXT+'V49/packaged_manifest.json'))
        assert manifest['kernel']=='V49' and manifest['compute_units']=='cpuOnly'
        expected={n[len(EXT):] for n in names if n.startswith(tuple([EXT+'V49/',EXT+'EnglishWords/',EXT+'Emoticons/']+[EXT+m+'/' for m in MODELS])) and not n.endswith('/') and n!=EXT+'V49/packaged_manifest.json'}
        assert set(manifest['files'])==expected,'Final manifest coverage mismatch'
        for name,digest in manifest['files'].items():assert hashlib.sha256(ipa.read(EXT+name)).hexdigest()==digest,name
        icons={n[len(BASE+'ToolIcons/'):]:hashlib.sha256(ipa.read(n)).hexdigest() for n in names if n.startswith(BASE+'ToolIcons/') and n.endswith('.png')}
        keyboard_icons={n[len(EXT+'ToolIcons/'):]:hashlib.sha256(ipa.read(n)).hexdigest() for n in names if n.startswith(EXT+'ToolIcons/') and n.endswith('.png')}
        assert icons and icons==keyboard_icons
    result={'build':109,'version':'0.1.106','kernel':'V49','source_checkpoint_sha256':CHECKPOINT,
            'source_local_step':1408,'source_global_step':94661,'compute_units':'cpuOnly',
            'paired_compiled_models':MODELS,'compiled_resources_verified':len(manifest['files']),
            'decoder_policy':'build109-word-initials-recall-1','maximum_visible_candidates':64,
            'english_dictionary_words':identity['english_dictionary_words'],
            'emoticon_entries':emoticons['total_entries'],'wechat_text_codes':emoticons['wechat_codes'],
            'wechat_image_regions':emoticons['real_image_regions'],'complete_current_wechat_claim':False,
            'inference_executed':False,'tests_executed':False,'user_device_acceptance':'pending'}
    Path(path).with_suffix('.verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result))
    return result

if __name__=='__main__':verify(sys.argv[1])
