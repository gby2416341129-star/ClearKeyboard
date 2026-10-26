#!/usr/bin/env python3
"""Original Qwen BF16 -> calibrated mixed LUT4 -> iOS18 MLKV packages.

The corpus is synthetic, not private typing history. Held-out agreement is a
conversion guard, not a claim of input-method accuracy or speed superiority.
"""
from __future__ import annotations

import argparse
import gc
import hashlib
import json
import math
from pathlib import Path
import sys
import time

import numpy as np
import torch
import torch.nn.functional as F
from safetensors import safe_open
from transformers import AutoTokenizer, Qwen3_5ForCausalLM, Qwen3_5TextConfig

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SYSTEM = "你是中文输入法。把全拼、简拼或混拼转成自然的常用中文词句；按语境选常用词，不机械拼接同音字。英文原样保留。只输出转换结果。"
REVISION = "2fc06364715b967f1860aea9cf38778875588b17"
STABLE_REFERENCE_FALLBACKS = []


def save_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def fetch_original(destination):
    sys.path.insert(0, str(ROOT / "Scripts"))
    from prepare_model import download_one
    import concurrent.futures
    lock = json.loads((HERE / "original.lock.json").read_text())
    if lock["revision"] != REVISION:
        raise RuntimeError("Original checkpoint revision differs from reviewed source")
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(download_one, f, lock, destination) for f in lock["files"]]
        for future in concurrent.futures.as_completed(futures):
            print(future.result(), flush=True)


def load_text(source):
    config = Qwen3_5TextConfig.from_dict(json.loads((source / "config.json").read_text())["text_config"])
    # Load only the text backbone, excluding the unused vision and MTP branches.
    with torch.device("meta"):
        model = Qwen3_5ForCausalLM(config)
    weights = {}
    for shard in source.glob("*.safetensors"):
        with safe_open(shard, framework="pt", device="cpu") as handle:
            for key in handle.keys():
                if key.startswith("model.language_model."):
                    weights["model." + key[len("model.language_model."):]] = handle.get_tensor(key)
    if "model.embed_tokens.weight" not in weights:
        raise RuntimeError("Missing text embedding in original checkpoint")
    weights["lm_head.weight"] = weights["model.embed_tokens.weight"]
    model.load_state_dict(weights, strict=True, assign=True)
    model = model.float().eval()
    model.tie_weights()
    # assign=True loads persistent checkpoint tensors only. RoPE frequencies
    # are non-persistent and otherwise remain on the meta device. Recreate
    # them explicitly; finite checkpoint weights alone are insufficient.
    from transformers.models.qwen3_5.modeling_qwen3_5 import Qwen3_5TextRotaryEmbedding
    model.model.rotary_emb = Qwen3_5TextRotaryEmbedding(config, device=torch.device("cpu"))
    unresolved = [name for name, value in list(model.named_parameters()) + list(model.named_buffers())
                  if value.is_meta]
    if unresolved:
        raise RuntimeError("Uninitialized meta tensors: " + ", ".join(unresolved))
    for name, value in model.named_buffers():
        if value.is_floating_point() and not torch.isfinite(value).all():
            raise RuntimeError("Non-finite initialized buffer: " + name)
    del weights
    gc.collect()
    print(f"Loaded text-only original: {sum(p.numel() for p in model.parameters()):,} parameters", flush=True)
    return model


def load_examples(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def make_batch(tokenizer, item):
    user = ("上文：" + item["context"] + "\n") if item["context"] else ""
    user += ("拼音：" + item["raw"]) if item["raw"] else "续写下一个词。"
    prefix = ("<|im_start|>system\n" + SYSTEM + "<|im_end|>\n<|im_start|>user\n"
              + user + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
    prefix_ids = tokenizer.encode(prefix, add_special_tokens=False)
    answer_ids = tokenizer.encode(item["target"], add_special_tokens=False)
    if not prefix_ids or not answer_ids:
        raise RuntimeError("Empty calibration prefix or answer")
    sequence = prefix_ids + answer_ids
    if len(sequence) > 256:
        raise RuntimeError(f"Unexpected long calibration example: {item['id']}")
    # Ask the head only for answer positions, avoiding a 248K-vocab projection
    # for every system/prompt token. These are exactly the next-token positions.
    score_positions = torch.arange(len(prefix_ids) - 1, len(sequence) - 1)
    return {"input_ids": torch.tensor([sequence]),
            "attention_mask": torch.ones(1, len(sequence), dtype=torch.long),
            "score_positions": score_positions, "answer_ids": torch.tensor(answer_ids),
            "id": item["id"], "category": item["category"]}


def forward_scores(model, batch):
    def run():
        return model(input_ids=batch["input_ids"], attention_mask=batch["attention_mask"],
                     logits_to_keep=batch["score_positions"], use_cache=False, return_dict=True).logits[0].float()
    scores = run()
    if torch.isfinite(scores).all():
        return scores
    # The CPU chunked DeltaNet implementation is a parallel factorization of
    # this same recurrent update. Retry a non-finite forward with the official
    # sequential FP32 recurrence and explicit attention math. Do not drop the
    # sample, alter its labels, replace NaNs, or update model weights.
    del scores
    from transformers.models.qwen3_5.modeling_qwen3_5 import torch_recurrent_gated_delta_rule
    from torch.nn.attention import sdpa_kernel, SDPBackend
    def stable_sequence(query, key, value, g, beta, initial_state=None,
                        output_final_state=False, use_qk_l2norm_in_kernel=False, **unused):
        return torch_recurrent_gated_delta_rule(query, key, value, g, beta, initial_state,
            output_final_state, use_qk_l2norm_in_kernel)
    replaced = []
    for layer in model.model.layers:
        if hasattr(layer, "linear_attn"):
            mixer = layer.linear_attn
            replaced.append((mixer, mixer.chunk_gated_delta_rule))
            mixer.chunk_gated_delta_rule = stable_sequence
    try:
        with sdpa_kernel(SDPBackend.MATH):
            scores = run()
    finally:
        for mixer, original in replaced:
            mixer.chunk_gated_delta_rule = original
    if not torch.isfinite(scores).all():
        raise RuntimeError(f"Non-finite reference even with stable recurrence: {batch['id']}")
    STABLE_REFERENCE_FALLBACKS.append(batch["id"])
    print(f"Stable FP32 recurrent reference used for {batch['id']}", flush=True)
    return scores


@torch.no_grad()
def evaluate(model, batches):
    results = []
    for index, batch in enumerate(batches):
        logits = forward_scores(model, batch)
        if not torch.isfinite(logits).all():
            raise RuntimeError("Non-finite logits on holdout")
        log_probs = F.log_softmax(logits, dim=-1)
        positions = torch.arange(len(batch["answer_ids"]))
        nll = -log_probs[positions, batch["answer_ids"]]
        top = logits.argmax(dim=-1)
        results.append({"id": batch["id"], "category": batch["category"],
                        "nll": nll.tolist(), "top1": top.tolist()})
        if index % 8 == 0:
            print(f"Holdout {index + 1}/{len(batches)}", flush=True)
    return results


def compare(reference, current):
    count = 0
    agreement = 0
    first = 0
    ref_nll = 0.0
    cur_nll = 0.0
    cases = []
    for before, after in zip(reference, current, strict=True):
        if before["id"] != after["id"] or len(before["top1"]) != len(after["top1"]):
            raise RuntimeError("Holdout alignment changed")
        n = len(before["top1"])
        equal = sum(a == b for a, b in zip(before["top1"], after["top1"]))
        first_equal = before["top1"][0] == after["top1"][0]
        count += n
        agreement += equal
        first += int(first_equal)
        ref_nll += sum(before["nll"])
        cur_nll += sum(after["nll"])
        cases.append({"id": before["id"], "category": before["category"],
                      "firstTokenAgreement": first_equal, "tokenAgreement": equal / n,
                      "deltaNLL": (sum(after["nll"]) - sum(before["nll"])) / n})
    result = {"examples": len(reference), "scoredTokens": count,
              "referenceNLL": ref_nll / count, "quantizedNLL": cur_nll / count,
              "deltaNLL": (cur_nll - ref_nll) / count,
              "teacherForcedTop1Agreement": agreement / count,
              "firstTokenAgreement": first / len(reference), "cases": cases}
    # Engineering guards against a visibly broken conversion. They do not
    # establish typing accuracy and are deliberately documented as our choices.
    result["guardThresholds"] = {"maxDeltaNLL": 0.15, "minTop1Agreement": 0.85,
                                 "minFirstTokenAgreement": 0.85}
    result["guardPassed"] = (result["deltaNLL"] <= 0.15 and
                             result["teacherForcedTop1Agreement"] >= 0.85 and
                             result["firstTokenAgreement"] >= 0.85)
    return result


@torch.no_grad()
def export_embedding(model, destination):
    weight = model.model.embed_tokens.weight
    rows, hidden = weight.shape
    scales = torch.empty(rows, dtype=torch.float16)
    squared_error = 0.0
    squared_reference = 0.0
    with destination.open("wb") as handle:
        for start in range(0, rows, 1024):
            end = min(start + 1024, rows)
            block = weight[start:end].detach().float()
            maximum = block.abs().amax(dim=1)
            scale = torch.where(maximum > 0, maximum / 127, torch.ones_like(maximum)).half()
            if not torch.isfinite(scale).all() or not (scale > 0).all():
                raise RuntimeError("Embedding scales are non-finite or underflowed")
            q = torch.round(block / scale.float()[:, None]).clamp(-127, 127).to(torch.int8)
            reconstructed = q.float() * scale.float()[:, None]
            squared_error += (reconstructed - block).square().sum().item()
            squared_reference += block.square().sum().item()
            handle.write(q.numpy().tobytes())
            scales[start:end] = scale
            # Keep tied lm_head at this same deployed int8-dequantized value.
            # SKM excludes both this table and head, so no sensitivity key alias.
            weight[start:end].copy_(reconstructed)
        handle.write(scales.numpy().astype("<f2").tobytes())
    expected = rows * hidden + rows * 2
    if destination.stat().st_size != expected:
        raise RuntimeError("Embedding export size mismatch")
    return {"encoding": "int8_rowwise_fp16_scale", "vocab": rows, "hidden": hidden,
            "bytes": expected, "normalizedSquaredError": squared_error / squared_reference,
            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}


def module_policy(name, module):
    if not isinstance(module, torch.nn.Linear) or name == "lm_head":
        return None
    # Preserve the small decay/beta gates and their recurrent dynamics.
    if name.endswith((".in_proj_a", ".in_proj_b")):
        return None
    if module.weight.numel() < 4096 or module.out_features % 32:
        return None
    # Conservative first/last block precision; most large matrices remain LUT4.
    return 6 if name.startswith(("model.layers.0.", "model.layers.23.")) else 4


def skm_config(model, samples, overrides=None):
    from coremltools.optimize.torch.palettization import SKMPalettizerConfig
    modules = {}
    for name, module in model.named_modules():
        bits = overrides.get(name) if overrides is not None else module_policy(name, module)
        if bits is not None:
            # A separate palette per output row avoids forcing heterogeneous
            # rows to share just 16 values. This costs about 15 MB of LUT data.
            modules[name] = {"n_bits": bits, "granularity": "per_grouped_channel",
                             "group_size": 1, "channel_axis": 0, "cluster_dim": 1,
                             "enable_per_channel_scale": False, "lut_dtype": None}
    if not modules:
        raise RuntimeError("No eligible modules for calibrated quantization")
    return SKMPalettizerConfig.from_dict({"global_config": None,
        "module_name_configs": modules, "calibration_nsamples": samples})


def layer_errors(model, source, fisher_path):
    # Rank only actual LUT4 modules for possible selective promotion to LUT6.
    sensitivity = torch.load(fisher_path, map_location="cpu", weights_only=True)
    results = []
    shard = next(source.glob("*.safetensors"))
    with safe_open(shard, framework="pt", device="cpu") as handle, torch.no_grad():
        for name, module in model.named_modules():
            buffers = dict(module.named_buffers(recurse=False))
            lut = buffers.get("_COREML_/weight/lut")
            if lut is None:
                continue
            bits = int(round(math.log2(lut.shape[-2])))
            key = name + ".weight"
            original = handle.get_tensor("model.language_model." + key[len("model."):]).float()
            importance = sensitivity[key]
            denominator = (original.square() * importance).sum().item()
            error = ((module.weight - original).square() * importance).sum().item()
            results.append({"module": name, "bits": bits, "parameters": module.weight.numel(),
                            "weightedRelativeSquaredError": error / max(denominator, 1e-30)})
    del sensitivity
    gc.collect()
    return sorted(results, key=lambda item: item["weightedRelativeSquaredError"], reverse=True)


def restore_modules(model, source, names):
    with safe_open(next(source.glob("*.safetensors")), framework="pt", device="cpu") as handle, torch.no_grad():
        for name in names:
            module = model.get_submodule(name)
            original_key = "model.language_model." + (name + ".weight")[len("model."):]
            module.weight.copy_(handle.get_tensor(original_key).float())
            for key, _ in list(module.named_buffers(recurse=False)):
                if key.startswith("_COREML_/weight/"):
                    delattr(module, key)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "work/original")
    parser.add_argument("--out", type=Path, default=ROOT / "Models/Qwen3.5-0.8B-IME-Q4")
    parser.add_argument("--work", type=Path, default=ROOT / "work/q4")
    parser.add_argument("--reference-only", action="store_true")
    parser.add_argument("--sample-limit", type=int, default=0)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--kmeans-workers", type=int, default=2)
    args = parser.parse_args()
    torch.set_num_threads(args.threads)
    torch.manual_seed(42)
    np.random.seed(42)
    args.source.mkdir(parents=True, exist_ok=True)
    args.work.mkdir(parents=True, exist_ok=True)
    args.out.mkdir(parents=True, exist_ok=True)
    fetch_original(args.source)
    calibration_items = load_examples(HERE / "calibration.jsonl")
    holdout_items = load_examples(HERE / "holdout.jsonl")
    if len(calibration_items) != 128 or len(holdout_items) < 32:
        raise RuntimeError("Incomplete calibration / held-out corpus")
    if {x["target"] for x in calibration_items} & {x["target"] for x in holdout_items}:
        raise RuntimeError("Calibration/holdout target leakage")
    tokenizer = AutoTokenizer.from_pretrained(args.source, local_files_only=True)
    calibration = [make_batch(tokenizer, item) for item in calibration_items]
    holdout = [make_batch(tokenizer, item) for item in holdout_items]
    if args.sample_limit:
        holdout = holdout[:args.sample_limit]
    model = load_text(args.source)
    reference = evaluate(model, holdout)
    save_json(args.work / "reference.json", reference)
    if args.reference_only:
        print("Original checkpoint + actual IME prompt alignment: PASS", flush=True)
        return
    from coremltools.optimize.torch.palettization import SKMPalettizer
    from skm_unique import install as install_unique_kmeans
    install_unique_kmeans()
    embedding = export_embedding(model, args.out / "embed_weight.int8.bin")
    q8_reference = evaluate(model, holdout)
    q8_comparison = compare(reference, q8_reference)
    save_json(args.work / "q8-baseline.json", {"comparison": q8_comparison,
                                             "results": q8_reference})
    if not q8_comparison["guardPassed"]:
        raise RuntimeError("Embedding/head INT8 alone failed the original numerical guard")
    for name, parameter in model.named_parameters():
        module_name = name.rsplit(".", 1)[0]
        module = model.get_submodule(module_name)
        parameter.requires_grad_(module_policy(module_name, module) is not None)
    config = skm_config(model, len(calibration))
    compressor = SKMPalettizer(model, config)
    counter = 0
    def loss_fn(current_model, batch):
        nonlocal counter
        logits = forward_scores(current_model, batch)
        loss = F.cross_entropy(logits, batch["answer_ids"])
        if not torch.isfinite(loss):
            raise RuntimeError("Non-finite calibration loss")
        counter += 1
        if counter % 8 == 0:
            print(f"Fisher calibration {counter}/{len(calibration)} loss={loss.item():.4f}", flush=True)
        return loss
    fisher_path = args.work / "fisher.pt"
    compressor.compute_sensitivity(calibration, loss_fn, sensitivity_path=str(fisher_path),
                                   num_sensitivity_workers=1)
    model.zero_grad(set_to_none=True)
    gc.collect()
    checked_sensitivity = torch.load(fisher_path, map_location="cpu", weights_only=True)
    invalid_sensitivity = [name for name, value in checked_sensitivity.items()
                           if not torch.isfinite(value).all() or not (value > 0).all()]
    if invalid_sensitivity:
        raise RuntimeError("Invalid Fisher information: " + ", ".join(invalid_sensitivity[:8]))
    print(f"Validated finite positive Fisher tensors: {len(checked_sensitivity)}", flush=True)
    del checked_sensitivity
    gc.collect()
    model = compressor.compress(sensitivity_path=str(fisher_path),
        num_kmeans_workers=args.kmeans_workers, inplace=True)
    # coremltools retains a full FP32 baseline even with inplace=True, solely
    # for report(). We compute our own held-out comparison and do not need it.
    compressor._uncompressed_model = None
    gc.collect()
    rounds = []
    errors = []
    for attempt in range(5):
        candidate = evaluate(model, holdout)
        save_json(args.work / f"candidate-attempt-{attempt}.json", candidate)
        comparison = compare(reference, candidate)
        comparison["attempt"] = attempt
        rounds.append(comparison)
        save_json(args.work / "quality.json", {"rounds": rounds})
        errors = layer_errors(model, args.source, fisher_path)
        save_json(args.work / "layer-errors.json", errors)
        print("QUALITY " + json.dumps({k: v for k, v in comparison.items() if k != "cases"}), flush=True)
        if comparison["guardPassed"]:
            break
        if attempt == 4:
            raise RuntimeError("Calibrated LUT4 mixture failed held-out numerical guard; no release artifact")
        promote = [item["module"] for item in errors if item["bits"] == 4][:12]
        if not promote:
            raise RuntimeError("No LUT4 layer available for selective precision promotion")
        print("Promoting sensitive modules to LUT6: " + ", ".join(promote), flush=True)
        restore_modules(model, args.source, promote)
        compressor = SKMPalettizer(model, skm_config(model, len(calibration), {name: 6 for name in promote}))
        model = compressor.compress(sensitivity_path=str(fisher_path),
            num_kmeans_workers=args.kmeans_workers, inplace=True)
        compressor._uncompressed_model = None
        gc.collect()
    coverage = {str(bits): sum(item["parameters"] for item in errors if item["bits"] == bits)
                for bits in [4, 6]}
    if coverage["4"] <= coverage["6"]:
        raise RuntimeError("LUT4 no longer dominates body weights; do not mislabel the model")
    save_json(args.out / "quantization-quality.json", {
        "sourceRevision": REVISION, "syntheticCalibrationSamples": len(calibration),
        "heldoutExamples": len(holdout), "promptSource": "current IME ChatML system/user template",
        "paletteGrouping": "one independent scalar LUT per output row",
        "q8OnlyComparison": q8_comparison,
        "corpusSHA256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [HERE / "calibration.jsonl", HERE / "holdout.jsonl"]},
        "rounds": rounds, "bodyParameterCoverage": coverage,
        "stableReferenceFallbacks": STABLE_REFERENCE_FALLBACKS,
        "embedding": embedding, "layers": errors,
        "iphoneExecuted": False, "typingAccuracyValidated": False})
    # Native compiler only runs on macOS. Export imports intentionally occur
    # after CPU reference/quality work, so the loader can be checked on Windows.
    from export_coreml import export_chunks
    del compressor
    gc.collect()
    export = export_chunks(model, args.out)
    save_json(args.out / "coreml-export.json", export)
    fingerprint = hashlib.sha256(json.dumps(export, sort_keys=True).encode()).hexdigest()
    info = {"name": "Qwen3.5-0.8B IME calibrated mixed LUT4",
            "sourceRevision": REVISION, "fingerprint": fingerprint,
            "embeddingFile": "embed_weight.int8.bin", "embeddingEncoding": embedding["encoding"],
            "contextLength": 2048, "vocabSize": 248320, "hiddenSize": 1024,
            "precision": "body LUT4 with selected LUT6 / gates floating point / head INT8",
            "bytes": sum(p.stat().st_size for p in args.out.rglob("*") if p.is_file()),
            "iphoneANEExecutionValidated": False}
    save_json(args.out / "model-info.json", info)
    print("EXPORT READY " + json.dumps(info), flush=True)


if __name__ == "__main__":
    main()
