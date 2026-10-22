#!/usr/bin/env python3
"""Prepare one disposable simulator for actual keyboard-extension diagnostics.

This is test infrastructure, not a supported product API. It never changes a
physical device, fabricates keyboard chrome, or claims the extension has run.
"""
import argparse
import datetime
import json
import plistlib
import struct
import subprocess
import time
import uuid
from pathlib import Path


def command(args, timeout=45, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {args!r}\n{result.stderr[-2000:]}")
    return result


def sim(device, *args, timeout=45, check=True):
    return command(["xcrun", "simctl", *args[:1], device, *args[1:]], timeout, check)


def info(path):
    with (path / "Info.plist").open("rb") as stream:
        return plistlib.load(stream)


def prepare(args, report):
    uuid.UUID(args.device)
    app = args.app.resolve(strict=True)
    app_info = info(app)
    app_id = app_info["CFBundleIdentifier"]
    extensions = []
    for candidate in sorted((app / "PlugIns").glob("*.appex")):
        value = info(candidate)
        if value.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.keyboard-service":
            extensions.append((candidate, value))
    if len(extensions) != 1:
        raise RuntimeError(f"Expected one built keyboard extension, found {len(extensions)}")
    extension, extension_info = extensions[0]
    extension_id = extension_info["CFBundleIdentifier"]
    if not extension_id.startswith(app_id + "."):
        raise RuntimeError("Built keyboard identifier does not belong to the containing App")
    inventory = json.loads(command(["xcrun", "simctl", "list", "devices", "available", "-j"]).stdout)
    matches = [(runtime, value) for runtime, devices in inventory["devices"].items()
               for value in devices if value["udid"] == args.device]
    if len(matches) != 1 or "iOS" not in matches[0][0]:
        raise RuntimeError("The supplied UUID is not an available iOS simulator")
    runtime, device = matches[0]
    if args.expected_runtime and runtime != args.expected_runtime:
        raise RuntimeError(f"Wrong simulator runtime: {runtime}, expected {args.expected_runtime}")
    report.update(device=args.device, deviceName=device["name"], runtime=runtime,
                  appBundleIdentifier=app_id, extensionBundleIdentifier=extension_id,
                  appVersion=app_info.get("CFBundleShortVersionString"), appBuild=app_info.get("CFBundleVersion"),
                  extensionVersion=extension_info.get("CFBundleShortVersionString"), extensionBuild=extension_info.get("CFBundleVersion"),
                  preferenceIsTestInfrastructure=True, actualExtensionLaunched=False,
                  systemSettingsKeyboardListVerified=False, systemKeyboardPickerVerified=False,
                  preferenceWritesIncludeCustomKeyboard=False,
                  registrationEvidence="Installed App and extension identity only; initial keyboard configuration is unverified until actual System Settings confirms English and Emoji without 澈, performs Add, and the extension delivers input")
    if device["state"] != "Booted":
        raise RuntimeError("Setup requires the already booted, readiness-checked simulator")
    sim(args.device, "install", str(app), timeout=90)
    installed = Path(sim(args.device, "get_app_container", app_id, "app").stdout.strip())
    installed_extension = installed / "PlugIns" / extension.name
    if info(installed_extension)["CFBundleIdentifier"] != extension_id:
        raise RuntimeError("Installed keyboard does not match the built extension")
    # Do not read or mutate AppleKeyboards and do not restart the simulator.
    # The actual Settings UI must establish the initial native list and then
    # perform Add; installation and an absent preference key prove neither.
    report.update(keyboardPrefsReadback=None, keyboardPrefsReadbackStatus="unverified-not-read",
                  initialNativeKeyboardListVerified=False,
                  preferenceWritesPerformed=False, simulatorRestartPerformed=False)
    # Recheck public app services after installation. No URL is retried blindly.
    report["appServiceReadiness"] = dict(listappsCompleted=False,
                                         preferencesInstalled=False, safariInstalled=False,
                                         timeoutSeconds=45)
    try:
        listed = sim(args.device, "listapps", timeout=45, check=False)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("Booted simulator app-service inventory timed out after 45 seconds") from error
    if listed.returncode:
        raise RuntimeError("Booted simulator app-service inventory failed: " + listed.stderr[-800:])
    converted = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-"],
                               input=listed.stdout, capture_output=True, text=True, timeout=15)
    if converted.returncode:
        raise RuntimeError("Could not decode booted simulator app-service inventory: " + converted.stderr[-800:])
    apps = json.loads(converted.stdout)
    if not isinstance(apps, dict):
        raise RuntimeError("Booted simulator app-service inventory is not a dictionary")
    app_service = dict(listappsCompleted=True, preferencesInstalled="com.apple.Preferences" in apps,
                       safariInstalled="com.apple.mobilesafari" in apps, timeoutSeconds=45)
    report["appServiceReadiness"] = app_service
    if not app_service["preferencesInstalled"] or not app_service["safariInstalled"]:
        raise RuntimeError("Booted simulator app services did not register both Settings and Safari")
    readiness = args.output.parent / "keyboard-shell-readiness.png"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(4):
        board = sim(args.device, "spawn", "launchctl", "print", "system/com.apple.SpringBoard", timeout=20, check=False)
        image = sim(args.device, "io", "screenshot", str(readiness), timeout=20, check=False)
        if board.returncode == 0 and "state = running" in board.stdout and image.returncode == 0 and readiness.is_file():
            png = readiness.read_bytes()
            if png[:8] == b"\x89PNG\r\n\x1a\n" and len(png) > 100:
                width, height = struct.unpack(">II", png[16:24])
                if width >= 300 and height >= 300:
                    report.update(status="installed-awaiting-system-settings-verification", readinessPixels=[width, height], readinessAttempts=attempt + 1)
                    return
        time.sleep(1)
    raise RuntimeError("Booted simulator did not provide a live SpringBoard and usable screenshot")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Explicit UUID of a disposable iOS simulator")
    parser.add_argument("--app", required=True, type=Path, help="Built simulator .app containing the actual .appex")
    parser.add_argument("--expected-runtime", help="Exact CoreSimulator runtime identifier, when required")
    parser.add_argument("--output", type=Path, default=Path(".build/KeyboardShell/setup.json"))
    args = parser.parse_args()
    report = {"status": "not-prepared", "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    try:
        prepare(args, report)
    except Exception as error:
        report.update(status="failed", error=str(error))
        raise
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
        print("KEYBOARD_SHELL_SIM_SETUP " + json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
