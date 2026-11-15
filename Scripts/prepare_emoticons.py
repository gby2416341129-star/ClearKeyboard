"""Stage only 106 screenshot-whitelisted original PNGs; never execute the IME."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Core/Resources/Emoticons"


def main():
    if DEST.resolve().parent != (ROOT / "Core/Resources").resolve():
        raise RuntimeError("Resource target escaped its explicit directory")
    manifest = json.loads((DEST / "manifest.json").read_text(encoding="utf-8"))
    catalog = json.loads((DEST / "catalog.json").read_text(encoding="utf-8"))
    whitelist = json.loads((DEST / "whitelist.json").read_text(encoding="utf-8"))
    if not (manifest["total_entries"] == manifest["wechat_codes"] == manifest["real_image_regions"] == 106
            and catalog["schema"] == "clear-emoticons-user-whitelist/1"
            and len(catalog["entries"]) == len(set(catalog["allowedCodes"])) == 106
            and catalog["allowedCodes"] == whitelist["allowedCodes"]
            and [entry["code"] for entry in catalog["entries"]] == whitelist["allowedCodes"]
            and all(entry["kind"] == "wechat" for entry in catalog["entries"])):
        raise RuntimeError("User screenshot whitelist identity mismatch")
    files = manifest["files"]
    images = [(name, row) for name, row in files.items() if name.startswith("Images/")]
    if len(images) != 106 or {name for name, _ in images} != {entry["image"] for entry in catalog["entries"]}:
        raise RuntimeError("Exactly the 106 whitelisted PNGs are required")
    for name in ["wechat-source-sprite.png", "LICENSE-MIT.txt", "LICENSE-ISC.txt", "UPSTREAM-NPM-PACKAGE.json"]:
        (DEST / name).unlink(missing_ok=True)
    allowed = set(files) | {"manifest.json"}
    if any(p.relative_to(DEST).as_posix() not in allowed for p in DEST.rglob("*") if p.is_file()):
        raise RuntimeError("Unexpected old/non-whitelisted resource")

    def stage(pair):
        name, row = pair
        path = DEST / name
        if path.resolve().parent != (DEST / "Images").resolve() or not path.name.startswith("wx-") or path.suffix != ".png":
            raise RuntimeError("Invalid source PNG path")
        if path.exists():
            data = path.read_bytes()
            if len(data) == row["bytes"] and hashlib.sha256(data).hexdigest() == row["sha256"]:
                return
        url = row["url"]
        if not (url.startswith("https://res.wx.qq.com/t/wx_fed/we-emoji/res/v1.3.10/assets/")
                or url.startswith("https://raw.githubusercontent.com/airinghost/wechat-emoji/2896eb55348041f5c5a66e4eccfb4882ab9cda0c/")):
            raise RuntimeError("Unpinned source URL")
        request = urllib.request.Request(url, headers={"User-Agent": "ClearKeyboard-resource-stage"})
        with urllib.request.urlopen(request, timeout=45) as response:
            data = response.read(row["bytes"] + 1)
        if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
            raise RuntimeError("PNG identity mismatch: " + name)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".png.download")
        temporary.write_bytes(data)
        temporary.replace(path)

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(stage, images))
    for name, row in files.items():
        data = (DEST / name).read_bytes()
        if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
            raise RuntimeError("Resource identity mismatch: " + name)
    print("106 screenshot-whitelisted original PNGs staged and SHA256 verified")


if __name__ == "__main__":
    main()
