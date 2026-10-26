#!/usr/bin/env python3
"""Delivery-only checks: device executables, exact model and resource cleanup."""
import hashlib
from pathlib import PurePosixPath
import plistlib
import struct
import sys
import zipfile
from prepare_qwen import MODEL_NAME, MODEL_SHA256, MODEL_BYTES


def verify(path):
    with zipfile.ZipFile(path) as ipa:
        names = ipa.namelist()
        base = 'Payload/ClearKeyboard.app/'
        extension = base + 'PlugIns/ClearKeyboardExtension.appex/'
        for executable in [base + 'ClearKeyboard', extension + 'ClearKeyboardExtension']:
            with ipa.open(executable) as stream: header = stream.read(32)
            assert struct.unpack_from('<I', header)[0] == 0xfeedfacf, 'Not a thin Mach-O device executable'
            assert struct.unpack_from('<I', header, 4)[0] == 0x100000c, 'Not arm64'
        model_paths = [name for name in names if name.lower().endswith('.gguf')]
        assert model_paths == [base + 'Models/' + MODEL_NAME], 'Model must be packaged exactly once in the App'
        model = model_paths[0]
        assert ipa.getinfo(model).file_size == MODEL_BYTES
        with ipa.open(model) as stream: assert hashlib.file_digest(stream, 'sha256').hexdigest() == MODEL_SHA256
        for name in names:
            lower = name.lower()
            assert not any(word in lower for word in ['rime', 'wanxiang', '.gram', 'clear-sentence', 'clearsentence25m', 'mmproj']), name
            assert not lower.endswith(('.clm', '.mlmodelc', '.mlpackage', '.part', '.tar.gz', '.dSYM'.lower())), name
        for resource in ['Phonetics/unicode-pinyin.tsv', 'english.clx']:
            assert base + resource in names, resource
            assert extension + resource not in names, 'Duplicate input resource'
        for prefix in [base, extension]:
            info = plistlib.loads(ipa.read(prefix + 'Info.plist'))
            assert str(info['CFBundleVersion']) == '78'
            assert 'iPhoneOS' in info['CFBundleSupportedPlatforms']
        info = plistlib.loads(ipa.read(extension + 'Info.plist'))
        assert info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.keyboard-service'
    print('IPA device binaries, single pinned Qwen model and resources verified.')


if __name__ == '__main__': verify(sys.argv[1])
