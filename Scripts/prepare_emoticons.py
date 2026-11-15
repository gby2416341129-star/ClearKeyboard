"""Stage an unchanged, pinned official source sprite. No model or IME is run."""
from pathlib import Path
import hashlib
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Core/Resources/Emoticons/wechat-source-sprite.png"
URL = "https://raw.githubusercontent.com/wechat-miniprogram/miniprogram-component-plus/2aad739689acf4ed19066ce171f2e17d7c62c4ba/docs/img/emoji-sprite.png"
SHA256 = "a79df3f4f8cc58ad11a3b93ebdc8d08b053fa6efd1e511552a215c493cea6594"
BYTES = 616827


def main():
    if DEST.is_file():
        data = DEST.read_bytes()
        if len(data) == BYTES and hashlib.sha256(data).hexdigest() == SHA256:
            print("Emoticons source sprite already staged; SHA256 verified")
            return
    request = urllib.request.Request(URL, headers={"User-Agent": "ClearKeyboard-resource-stage"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(BYTES + 1)
    if len(data) != BYTES or hashlib.sha256(data).hexdigest() != SHA256:
        raise RuntimeError("Pinned official emoticon sprite identity mismatch; nothing installed")
    DEST.parent.mkdir(parents=True, exist_ok=True)
    temporary = DEST.with_suffix(".png.download")
    temporary.write_bytes(data)
    temporary.replace(DEST)
    print("Emoticons source sprite staged; SHA256 verified")


if __name__ == "__main__":
    main()
