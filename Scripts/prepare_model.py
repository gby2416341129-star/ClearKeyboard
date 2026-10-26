#!/usr/bin/env python3
"""Fetch only the pinned Qwen 0.8B MLKV bundle; never touch ClearKeyboard.

Uses the Python standard library. --metadata-only skips weight.bin / embeddings.
The lock captures the immutable Hub revision and every file's upstream digest.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path, PurePosixPath
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPO = "mlboydaisuke/qwen3.5-0.8B-CoreML"
REVISION = "82700f499b705c64c594c42deff684ec0321bcce"
BUNDLE = "qwen3_5_0_8b_decode_chunks_mlkv"
LOCK = ROOT / "model.lock.json"


def request_json(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def selected(path):
    return path == f"{BUNDLE}/embed_weight.bin" or any(
        path == f"{BUNDLE}/chunk_{chunk}.mlpackage/{tail}"
        for chunk in "abcd"
        for tail in ("Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
                     "Data/com.apple.CoreML/weights/weight.bin")
    ) or path == "LICENSE"


def make_lock():
    info = request_json(f"https://huggingface.co/api/models/{REPO}/revision/{REVISION}?blobs=true")
    revision = info["sha"]
    files = []
    for entry in info["siblings"]:
        path = entry["rfilename"]
        if selected(path):
            lfs = entry.get("lfs")
            files.append({"path": path, "size": entry["size"],
                          "digest": lfs["sha256"] if lfs else entry["blobId"],
                          "algorithm": "sha256" if lfs else "git-blob-sha1"})
    required = 13
    if len([f for f in files if f["path"].startswith(BUNDLE + "/")]) != required:
        raise RuntimeError("Expected four complete chunks plus one embedding file")
    lock = {"repo": REPO, "revision": revision, "bundle": BUNDLE,
            "upstream_runtime_commit": "e45a7a61dd7e35ba58dd14aa7a8f843c8caa3f0f",
            "files": sorted(files, key=lambda f: f["path"])}
    LOCK.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
    return lock


def digest_file(path, algorithm):
    size = path.stat().st_size
    digest = hashlib.sha256() if algorithm == "sha256" else hashlib.sha1()
    if algorithm == "git-blob-sha1":
        digest.update(f"blob {size}\0".encode())
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verified(path, spec):
    return (path.is_file() and path.stat().st_size == spec["size"]
            and digest_file(path, spec["algorithm"]) == spec["digest"])


def download_one(spec, lock, destination):
    relative = PurePosixPath(spec["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("Unsafe path in lock")
    path = destination.joinpath(*relative.parts)
    if verified(path, spec):
        return f"verified {spec['path']}"
    path.parent.mkdir(parents=True, exist_ok=True)
    url = (f"https://huggingface.co/{lock['repo']}/resolve/{lock['revision']}/"
           + urllib.parse.quote(spec["path"], safe="/"))
    temporary = path.with_name(path.name + ".partial")
    with urllib.request.urlopen(url, timeout=180) as response, temporary.open("wb") as output:
        while block := response.read(1024 * 1024):
            output.write(block)
    if not verified(temporary, spec):
        temporary.unlink(missing_ok=True)
        raise RuntimeError(f"Digest mismatch: {spec['path']}")
    temporary.replace(path)
    return f"downloaded {spec['path']} ({spec['size']:,} bytes)"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", action="store_true", help="Rebuild manifest for the reviewed, pinned revision")
    parser.add_argument("--metadata-only", action="store_true")
    parser.add_argument("--destination", type=Path, default=ROOT / "Models")
    args = parser.parse_args()
    if args.lock:
        lock = make_lock()
    elif LOCK.exists():
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
    else:
        parser.error("No model.lock.json; inspect the source and run --lock once")
    if lock["repo"] != REPO or lock["revision"] != REVISION or lock["bundle"] != BUNDLE:
        parser.error("Lock differs from reviewed runtime contract; review code and assets together")
    files = [f for f in lock["files"] if not args.metadata_only or not f["path"].endswith(".bin")]
    print(f"repo={lock['repo']} revision={lock['revision']}")
    print(f"selected={len(files)} files; full bundle={sum(f['size'] for f in lock['files']):,} bytes")
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(download_one, f, lock, args.destination) for f in files]
        for future in concurrent.futures.as_completed(futures):
            print(future.result(), flush=True)


if __name__ == "__main__":
    main()
