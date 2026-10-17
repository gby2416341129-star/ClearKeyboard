#!/usr/bin/env python3
"""Check the unsigned delivery contains both arm64 iOS device executables.

Structural checks do not replace code-signature verification or device testing.
"""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def device_executable(data):
    require(len(data) >= 32, "Missing Mach-O executable")
    magic, cpu, subtype, filetype, commands, command_bytes, flags, reserved = struct.unpack_from("<8I", data)
    require(magic == 0xFEEDFACF, "Expected a thin 64-bit Mach-O")
    require(cpu == 0x0100000C, "Executable is not arm64")
    require(filetype == 2, "Mach-O is not an executable")
    require(32 + command_bytes <= len(data), "Truncated Mach-O load commands")
    offset = 32
    platform = None
    for _ in range(commands):
        require(offset + 8 <= 32 + command_bytes, "Invalid Mach-O command table")
        command, size = struct.unpack_from("<2I", data, offset)
        require(size >= 8 and offset + size <= 32 + command_bytes, "Invalid Mach-O command size")
        if command == 0x32:  # LC_BUILD_VERSION: iOS=2, iOS Simulator=7
            require(size >= 24, "Truncated build version")
            platform = struct.unpack_from("<I", data, offset + 8)[0]
        offset += size
    require(platform == 2, "Executable is not built for the iOS device platform")
    return {"architecture": "arm64", "platform": "iOS device"}


def verify(path):
    bundles = []
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP members")
        require(archive.testzip() is None, "Corrupt ZIP member")
        app = "Payload/ClearKeyboard.app/"
        extension = app + "PlugIns/ClearKeyboardExtension.appex/"
        app_id = None
        app_version = None
        for prefix, kind in [(app, "APPL"), (extension, "XPC!")]:
            info = plistlib.loads(archive.read(prefix + "Info.plist"))
            require(info.get("CFBundlePackageType") == kind, "Incorrect bundle type")
            require("iPhoneOS" in info.get("CFBundleSupportedPlatforms", []), "Bundle is not for iPhoneOS")
            identifier = info["CFBundleIdentifier"]
            executable = info["CFBundleExecutable"]
            require("/" not in executable and executable not in ("", ".", ".."), "Invalid executable name")
            require("$(" not in identifier, "Unexpanded bundle identifier")
            if app_id is None:
                app_id = identifier
                app_version = (info["CFBundleShortVersionString"], info["CFBundleVersion"])
            else:
                require(identifier == app_id + ".Keyboard", "Keyboard bundle identifier mismatch")
                require((info["CFBundleShortVersionString"], info["CFBundleVersion"]) == app_version, "App and keyboard version mismatch")
                require(info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.keyboard-service", "Missing keyboard extension registration")
            binary = device_executable(archive.read(prefix + executable))
            member = archive.getinfo(prefix + executable)
            require((member.external_attr >> 16) & 0o111, "Executable permission missing")
            for resource in ("pinyin.clx", "english.clx"):
                with archive.open(prefix + resource) as stream:
                    require(stream.read(8) == b"CLRX0001", "Missing or incorrect offline dictionary")
            with archive.open(prefix + "associations.clx") as stream:
                require(stream.read(8) == b"CLRX0001", "Missing association and mixed-English dictionary")
            rime = app + "Rime/"
            for resource in ("build/clear_pinyin.schema.yaml", "build/clear_pinyin.table.bin", "build/clear_pinyin.prism.bin", "lua/clear_span.lua"):
                require(rime + resource in names, "Missing precompiled Rime resource: " + resource)
            require(rime + "wanxiang-lts-zh-hans.gram" in names, "Missing context language model")
            corrections = archive.read(prefix + 'pinyin-corrections.clx')
            require(len(corrections) >= 48 and corrections[:8] == b'CLRC0001', 'Missing spelling-correction index')
            words, records = struct.unpack_from('<2I', corrections, 8)
            require(len(corrections) == 48 + records * 12, 'Truncated spelling-correction index')
            dictionary = archive.read(prefix + 'pinyin.clx')
            require(words == struct.unpack_from('<I', dictionary, 8)[0], 'Spelling index uses a different vocabulary')
            require(corrections[16:48] == hashlib.sha256(dictionary).digest(), 'Spelling index source checksum mismatch')
            require(prefix + "PrivacyInfo.xcprivacy" in names, "Privacy manifest missing")
            bundles.append({"bundleIdentifier": identifier, **binary})
        with archive.open(app + "Rime/wanxiang-lts-zh-hans.gram") as stream:
            require(hashlib.file_digest(stream, "sha256").hexdigest() == "1849e5e4acbdbfaf41fceeb86b739d5d0c85d574bd8a688562cba1e6beb78488", "Context model checksum mismatch")
    return {
        "status": "passed",
        "checks": "ZIP integrity, bundle metadata, extension registration, executable permissions, arm64 iOS load commands, offline dictionaries, spelling-correction index and source checksum, privacy manifests",
        "bundles": bundles,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "signing": "unsigned build; no signing verification performed",
        "installableAsDelivered": False,
        "deviceTesting": "not performed",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.ipa), indent=2))
