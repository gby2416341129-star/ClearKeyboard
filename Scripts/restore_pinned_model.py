#!/usr/bin/env python3
"""Recover the pinned model from a prior IPA when the upstream LTS asset moves."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

from prepare_rime import ASSETS, CACHE

NAME = "wanxiang-lts-zh-hans.gram"
EXPECTED = ASSETS[NAME][1]


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def restore_from_ipa(ipa, destination):
    part = destination.with_suffix(destination.suffix + ".part")
    try:
        with zipfile.ZipFile(ipa) as archive:
            models = [name for name in archive.namelist() if name.endswith("/" + NAME)]
            if len(models) != 1:
                raise RuntimeError("Expected exactly one shared language model")
            with archive.open(models[0]) as source, part.open("wb") as output:
                shutil.copyfileobj(source, output, 4 * 1024 * 1024)
        actual = digest(part)
        if actual != EXPECTED:
            raise RuntimeError(f"Prior IPA contains a different model: {actual}")
        part.replace(destination)
    finally:
        part.unlink(missing_ok=True)


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def main():
    CACHE.mkdir(exist_ok=True)
    destination = CACHE / NAME
    if destination.exists() and digest(destination) == EXPECTED:
        print("Pinned language model verified in cache", flush=True)
        return
    repository = os.environ["GITHUB_REPOSITORY"]
    runs = api(f"repos/{repository}/actions/workflows/ipa.yml/runs?status=success&branch=main&per_page=20")
    attempted = 0
    for run in runs["workflow_runs"]:
        artifacts = api(f"repos/{repository}/actions/runs/{run['id']}/artifacts")
        if not any(a["name"] == "ClearKeyboard-unsigned-IPA" and not a["expired"]
                   for a in artifacts["artifacts"]):
            continue
        attempted += 1
        with tempfile.TemporaryDirectory(prefix="pinned-model-", dir=CACHE) as temporary:
            folder = Path(temporary)
            subprocess.run(["gh", "run", "download", str(run["id"]), "--repo", repository,
                            "--name", "ClearKeyboard-unsigned-IPA", "--dir", str(folder)], check=True)
            ipas = list(folder.rglob("*.ipa"))
            if len(ipas) != 1:
                raise RuntimeError("Prior build artifact did not contain exactly one IPA")
            try:
                restore_from_ipa(ipas[0], destination)
            except RuntimeError as error:
                print(f"Build {run['id']} cannot supply this pinned model: {error}", flush=True)
            else:
                print(f"Recovered and SHA-256 verified pinned model from build {run['id']}", flush=True)
                return
        if attempted >= 3:
            break
    raise RuntimeError("No retained successful IPA contains the pinned language model")


if __name__ == "__main__":
    main()
