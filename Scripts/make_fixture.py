#!/usr/bin/env python3
"""Generate one technical smoke fixture using the original Qwen tokenizer.

Requires tokenizers==0.22.2. This is not a typing-quality benchmark.
"""
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    from tokenizers import Tokenizer
    with urllib.request.urlopen("https://huggingface.co/api/models/Qwen/Qwen3.5-0.8B") as response:
        revision = json.load(response)["sha"]
    with urllib.request.urlopen(
        f"https://huggingface.co/Qwen/Qwen3.5-0.8B/resolve/{revision}/tokenizer.json"
    ) as response:
        data = response.read()
    tokenizer = Tokenizer.from_str(data.decode("utf-8"))
    # Explicit non-thinking ChatML input, used identically on each target device.
    prompt = "<|im_start|>user\n请只回答：你好。<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    token_ids = tokenizer.encode(prompt, add_special_tokens=False).ids
    assert all(0 <= token < 248320 for token in token_ids)
    fixture = {"prompt": prompt, "tokenIDs": token_ids,
               "tokenizerRepo": "Qwen/Qwen3.5-0.8B", "tokenizerRevision": revision,
               "tokenizerSHA256": hashlib.sha256(data).hexdigest()}
    (ROOT / "ProbeApp/fixture.json").write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Created {len(token_ids)}-token smoke fixture; tokenizer revision {revision}")


if __name__ == "__main__":
    main()
