"""Export calibrated HF text weights to the independent iOS 18 MLKV contract.

This module consumes PyTorch compression metadata produced by SKM. It never
loads, repalettizes, or otherwise requantizes a previously exported Core ML
package. Conversion and protobuf inspection do not prove device ANE placement.
"""
from __future__ import annotations

from collections import Counter
import gc
import importlib
import json
import math
from pathlib import Path
import sys
import time

import numpy as np
import torch


HERE = Path(__file__).resolve().parent
WEIGHT_PREFIX = "_COREML_/weight/"
METADATA_VERSION = "_COREML_/metadata_version"
CHUNK_NAMES = ("chunk_a", "chunk_b", "chunk_c", "chunk_d")


def _copy_linear_metadata(source, destination):
    """Keep SKM's calibrated LUT when a rank-2 Linear becomes a rank-4 Conv.

    LUT layout is [weight group dimensions..., palette entries, vector size].
    Consequently the two singleton kernel axes precede the last two LUT axes.
    Compression enums and n_bits are integer buffers and must stay integer.
    """
    for name, value in source.named_buffers(recurse=False):
        if not name.startswith(WEIGHT_PREFIX):
            continue
        field = name[len(WEIGHT_PREFIX):]
        copied = value.detach().cpu().clone()
        if field == "lut":
            # Scalar LUTs may omit the trailing vector-size axis.
            if copied.ndim == 3:
                copied = copied.unsqueeze(-1)
            if copied.ndim != 4:
                raise ValueError(f"Expected rank-4 Linear LUT, got {tuple(copied.shape)}")
            copied = copied.unsqueeze(2).unsqueeze(3)
        elif field in ("palettization_scale", "quantization_scale", "zero_point"):
            if copied.ndim == 2:
                copied = copied.unsqueeze(-1).unsqueeze(-1)
            if copied.ndim != 4:
                raise ValueError(f"Invalid {field} rank for converted Conv: {copied.ndim}")
        if copied.is_floating_point():
            copied = copied.to(destination.weight.dtype)
        destination.register_buffer(name, copied.contiguous())


def _load_builder():
    """Patch the factory before MLKV imports its local reference to it."""
    upstream = HERE / "upstream"
    for filename in ("ane_ops.py", "qwen3_5_decode_layer_mlkv.py",
                     "build_qwen35_decode_chunks_mlkv.py"):
        if not (upstream / filename).is_file():
            raise FileNotFoundError(upstream / filename)
    sys.path.insert(0, str(upstream))
    ane_ops = importlib.import_module("ane_ops")
    if Path(ane_ops.__file__).resolve().parent != upstream.resolve():
        raise RuntimeError("Refusing to use an ane_ops module from another source tree")
    old_factory = ane_ops.conv_from_linear
    if not getattr(old_factory, "_preserves_skm_metadata", False):
        def calibrated_conv_from_linear(linear, dtype=ane_ops.MODEL_DTYPE):
            result = old_factory(linear, dtype=dtype)
            _copy_linear_metadata(linear, result.conv)
            return result
        calibrated_conv_from_linear._preserves_skm_metadata = True
        ane_ops.conv_from_linear = calibrated_conv_from_linear
    # A caller must not import this builder first: that would have captured the
    # unpatched factory and could silently lose the calibrated LUTs.
    layer_name = "qwen3_5_decode_layer_mlkv"
    if layer_name in sys.modules:
        layer = sys.modules[layer_name]
        if not getattr(layer.conv_from_linear, "_preserves_skm_metadata", False):
            raise RuntimeError("MLKV layer was imported before installing the metadata factory")
    builder = importlib.import_module("build_qwen35_decode_chunks_mlkv")
    if Path(builder.__file__).resolve().parent != upstream.resolve():
        raise RuntimeError("Refusing to use an MLKV builder from another source tree")
    return builder


@torch.no_grad()
def _register_head_int8(conv):
    """Quantize the actual traced head, rather than merely tagging FP weights.

    Processing rows in blocks avoids an extra full-vocabulary FP32 head copy.
    Scale is FP16, matching the weight/output precision of this export. The
    caller's embedding has already been simulated at rowwise INT8 precision;
    the small additional roundoff here is reported explicitly.
    """
    if conv.weight.ndim != 4 or tuple(conv.weight.shape[2:]) != (1, 1):
        raise ValueError("Head must be a 1x1 Conv")
    if any(name.startswith(WEIGHT_PREFIX) for name in conv._buffers):
        raise RuntimeError("Head unexpectedly has SKM metadata; refusing double compression")
    rows = conv.weight.shape[0]
    scales = torch.empty((rows, 1, 1, 1), dtype=torch.float16)
    max_abs_error = 0.0
    squared_error = 0.0
    squared_reference = 0.0
    changed_values = 0
    for start in range(0, rows, 2048):
        end = min(start + 2048, rows)
        original = conv.weight[start:end].detach().float()
        peak = original.abs().flatten(1).amax(1).reshape(-1, 1, 1, 1)
        scale = (peak / 127.0).to(torch.float16)
        scale = torch.where(peak == 0, torch.ones_like(scale), scale)
        if not torch.isfinite(scale).all() or (scale <= 0).any():
            raise RuntimeError("Unrepresentable FP16 scale in the INT8 head")
        q = torch.round(original / scale.float()).clamp(-127, 127)
        dequantized = (q * scale.float()).to(conv.weight.dtype)
        # This is the same round-and-scale recovery used by the Core ML
        # compression frontend. Check it before discarding the integer values.
        recovered = torch.round(dequantized.float() / scale.float()).clamp(-127, 127)
        if not torch.equal(q, recovered):
            raise RuntimeError("Head quant-dequant is not stable at the exported precision")
        difference = dequantized.float() - original
        max_abs_error = max(max_abs_error, float(difference.abs().max()))
        squared_error += float(difference.square().sum())
        squared_reference += float(original.square().sum())
        changed_values += int(torch.count_nonzero(difference))
        conv.weight[start:end].copy_(dequantized)
        scales[start:end].copy_(scale)
    conv.register_buffer(WEIGHT_PREFIX + "quantization_n_bits", torch.tensor(8))
    conv.register_buffer(WEIGHT_PREFIX + "quantization_scale", scales)
    conv.register_buffer(WEIGHT_PREFIX + "compression_type", torch.tensor([3]))
    return {
        "scheme": "symmetric_rowwise_int8", "scale_dtype": "float16",
        "weight_shape": list(conv.weight.shape), "quant_dequant_stable": True,
        "additional_max_abs_error": max_abs_error,
        "additional_relative_l2_error": math.sqrt(squared_error / max(squared_reference, 1e-30)),
        "additional_changed_values": changed_values,
    }


def _expected_palette_counts(chunk):
    counts = Counter()
    for module in chunk.modules():
        lut = module._buffers.get(WEIGHT_PREFIX + "lut")
        if lut is None:
            continue
        entries = int(lut.shape[-2])
        bits = int(math.log2(entries))
        if 2 ** bits != entries or bits not in (4, 6):
            raise RuntimeError(f"Expected calibrated LUT4/LUT6, got {entries} entries")
        if lut.ndim != module.weight.ndim + 2:
            raise RuntimeError("Compression LUT dimensions do not match converted weights")
        counts[str(bits)] += 1
    if not counts:
        raise RuntimeError("No calibrated SKM metadata reached the chunk")
    return counts


def _tensor_info(value_type, mil_proto):
    if not value_type.HasField("tensorType"):
        return None
    tensor = value_type.tensorType
    shape = []
    for dim in tensor.dimensions:
        if not dim.HasField("constant"):
            return {"dtype": mil_proto.DataType.Name(tensor.dataType), "shape": None}
        shape.append(int(dim.constant.size))
    return {"dtype": mil_proto.DataType.Name(tensor.dataType), "shape": shape}


def _audit_package(package, expected_palettes, head_shape, expected_inputs, expected_outputs):
    """Inspect the saved protobuf and typed compression inputs, not file labels."""
    from coremltools.proto import MIL_pb2, Model_pb2

    manifest = json.loads((package / "Manifest.json").read_text(encoding="utf-8"))
    root = manifest["itemInfoEntries"][manifest["rootModelIdentifier"]]["path"]
    spec_path = package / "Data" / root
    if not spec_path.is_file():
        raise FileNotFoundError(f"Missing saved package protobuf: {spec_path}")
    spec = Model_pb2.Model()
    spec.ParseFromString(spec_path.read_bytes())
    if spec.WhichOneof("Type") != "mlProgram":
        raise RuntimeError("Export is not an ML Program")
    if [item.name for item in spec.description.input] != expected_inputs:
        raise RuntimeError("Converted input contract changed")
    if [item.name for item in spec.description.output] != expected_outputs:
        raise RuntimeError("Converted output contract changed")
    if [item.name for item in spec.description.state] != ["kv_cache"]:
        raise RuntimeError("Expected exactly one kv_cache MLState")

    operations = []
    values = {}
    def scan(block):
        for op in block.operations:
            operations.append(op)
            for output in op.outputs:
                values[output.name] = (output, op)
            for nested in op.blocks:
                scan(nested)
    for function in spec.mlProgram.functions.values():
        for block in function.block_specializations.values():
            scan(block)

    def input_info(op, key):
        argument = op.inputs.get(key)
        if argument is None or len(argument.arguments) != 1:
            return None
        binding = argument.arguments[0]
        if binding.WhichOneof("binding") == "name":
            if binding.name not in values:
                raise RuntimeError(f"Cannot resolve saved compression input {binding.name}")
            return _tensor_info(values[binding.name][0].type, MIL_pb2)
        if binding.WhichOneof("binding") == "value":
            return _tensor_info(binding.value.type, MIL_pb2)
        return None

    op_counts = Counter(op.type for op in operations)
    palette_counts = Counter()
    quantized_data_counts = Counter()
    compression_ops = []
    head_int8_count = 0
    full_float_heads = []
    for op in operations:
        if op.type == "const" and head_shape is not None:
            for output in op.outputs:
                info = _tensor_info(output.type, MIL_pb2)
                if (info and info["shape"] and info["dtype"] in ("FLOAT16", "FLOAT32")
                        and math.prod(info["shape"]) == math.prod(head_shape)):
                    full_float_heads.append(output.name)
        if not op.type.startswith("constexpr_"):
            continue
        row = {"operator": op.type, "outputs": [x.name for x in op.outputs]}
        if op.type == "constexpr_lut_to_dense":
            info = input_info(op, "indices")
            if not info or info["dtype"] not in ("UINT4", "UINT6"):
                raise RuntimeError(f"Wrong LUT index storage in saved graph: {info}")
            bits = info["dtype"][4:]
            palette_counts[bits] += 1
            row["indices"] = info
        if op.type in ("constexpr_blockwise_shift_scale", "constexpr_affine_dequantize"):
            key = "data" if "data" in op.inputs else "quantized_data"
            info = input_info(op, key)
            if info:
                row["data"] = info
                if info["dtype"] in ("INT8", "UINT8"):
                    quantized_data_counts[info["dtype"]] += 1
                if head_shape is not None and info["shape"] == head_shape:
                    if info["dtype"] != "INT8":
                        raise RuntimeError(f"Head compressed data must be INT8, got {info}")
                    head_int8_count += 1
        compression_ops.append(row)
    if palette_counts != expected_palettes:
        raise RuntimeError(f"LUT metadata lost during export: expected {dict(expected_palettes)}, "
                           f"saved {dict(palette_counts)}")
    if head_shape is not None and (head_int8_count != 1 or full_float_heads):
        raise RuntimeError(f"Head storage audit failed: INT8 heads={head_int8_count}, "
                           f"full floating constants={full_float_heads}")
    if op_counts.get("topk", 0):
        raise RuntimeError("Unexpected topk in the full-logits export")
    return {
        "passed": True, "protobuf": str(spec_path.relative_to(package)),
        "operators": dict(sorted(op_counts.items())),
        "palette_bitwidth_counts": dict(sorted(palette_counts.items())),
        "quantized_data_dtype_counts": dict(sorted(quantized_data_counts.items())),
        "head_int8_count": head_int8_count,
        "full_float_head_constants": full_float_heads,
        "compression_operations": compression_ops,
    }


def export_chunks(hf_model, out_dir: Path, context_length=2048) -> dict:
    """Return measured package sizes and graph evidence for all four chunks.

    hf_model is a *text-only*, already calibrated Qwen3_5ForCausalLM. The
    embedding sidecar is exported by the caller. Output paths must be new;
    existing packages are preserved rather than silently compressed again.
    """
    import coremltools as ct

    builder = _load_builder()
    cfg = hf_model.config
    if hasattr(cfg, "text_config"):
        cfg = cfg.text_config
    if int(cfg.num_hidden_layers) != 24 or len(hf_model.model.layers) != 24:
        raise ValueError("This export contract is the 24-layer Qwen3.5-0.8B text backbone")
    if context_length < 1 or context_length > 2048:
        raise ValueError("Independent iPhone probe context must be within 1..2048")
    if int(cfg.head_dim * 0.25) != 64:
        raise ValueError("Expected Qwen3.5-0.8B's 64-element partial rotary embedding")
    out_dir = Path(out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    for name in CHUNK_NAMES:
        if (out_dir / f"{name}.mlpackage").exists():
            raise FileExistsError(f"Preserving existing package: {name}.mlpackage")

    records = []
    total_started = time.monotonic()
    # Build and release one chunk at a time: cloud Intel runners have 14 GB RAM.
    for index, name in enumerate(CHUNK_NAMES):
        started = time.monotonic()
        start, end = index * 6, (index + 1) * 6
        tail = index == 3
        chunk = (builder.MLKVTailChunk(cfg, hf_model, start, context_length) if tail
                 else builder.MLKVBodyChunk(cfg, hf_model, start, end, context_length))
        chunk = chunk.eval().requires_grad_(False)
        chunk.register_buffer(METADATA_VERSION, torch.tensor(1))
        expected_palettes = _expected_palette_counts(chunk)
        head_audit = _register_head_int8(chunk.lm_head.conv) if tail else None

        conv_shape, rec_shape = builder._ssm_state_shapes(cfg)
        # Position zero is exactly cos=1/sin=0. Avoid HF multimodal RoPE APIs,
        # whose axes/position-id conventions differ between Transformers builds.
        examples = [
            torch.zeros(1, 1, cfg.hidden_size, dtype=torch.float16),
            torch.ones(1, 1, 64, dtype=torch.float16),
            torch.zeros(1, 1, 64, dtype=torch.float16),
            torch.zeros(1, 1, 1, context_length, dtype=torch.float16),
            torch.zeros(1, dtype=torch.int32),
        ]
        inputs = [
            ct.TensorType(name="hidden_in", shape=(1, 1, cfg.hidden_size), dtype=np.float16),
            ct.TensorType(name="cos", shape=(1, 1, 64), dtype=np.float16),
            ct.TensorType(name="sin", shape=(1, 1, 64), dtype=np.float16),
            ct.TensorType(name="causal_mask", shape=(1, 1, 1, context_length), dtype=np.float16),
            ct.TensorType(name="current_pos", shape=(1,), dtype=np.int32),
        ]
        outputs = [ct.TensorType(name="logits" if tail else "hidden", dtype=np.float16)]
        for layer_index in chunk.lin_layer_indices:
            examples.extend((torch.zeros(conv_shape, dtype=torch.float16),
                             torch.zeros(rec_shape, dtype=torch.float16)))
            inputs.extend((ct.TensorType(name=f"conv_state_{layer_index}", shape=conv_shape, dtype=np.float16),
                           ct.TensorType(name=f"rec_state_{layer_index}", shape=rec_shape, dtype=np.float16)))
            outputs.extend((ct.TensorType(name=f"new_conv_state_{layer_index}", dtype=np.float16),
                            ct.TensorType(name=f"new_rec_state_{layer_index}", dtype=np.float16)))
        kv_shape = builder._kv_state_shape(cfg, max(chunk.full_count, 1), context_length)
        states = [ct.StateType(name="kv_cache", wrapped_type=ct.TensorType(shape=kv_shape, dtype=np.float16))]
        print(f"Export {name}: layers [{start}, {end}), calibrated LUTs={dict(expected_palettes)}", flush=True)
        with torch.no_grad():
            traced = torch.jit.trace(chunk, tuple(examples), strict=False, check_trace=False)
            chunk.kv_cache.zero_()
        # Compression metadata lives in state_dict; check it survived tracing.
        traced_luts = [key for key in traced.state_dict() if key.endswith(WEIGHT_PREFIX + "lut")]
        if len(traced_luts) != sum(expected_palettes.values()):
            raise RuntimeError("TorchScript discarded calibrated LUT metadata")
        package = out_dir / f"{name}.mlpackage"
        model = ct.convert(
            traced, source="pytorch", convert_to="mlprogram",
            inputs=inputs, outputs=outputs, states=states,
            minimum_deployment_target=ct.target.iOS18,
            compute_precision=ct.precision.FLOAT16,
            compute_units=ct.ComputeUnit.CPU_AND_NE,
            skip_model_load=True,
        )
        model.short_description = "Independent Qwen3.5-0.8B calibrated LUT4/6 + rowwise INT8 head; iOS18 MLKV"
        model.user_defined_metadata["compression_source"] = "original BF16 -> calibrated SKM PyTorch metadata"
        model.user_defined_metadata["device_ane_verified"] = "false"
        model.save(str(package))
        compression_audit = _audit_package(
            package, expected_palettes,
            head_audit["weight_shape"] if head_audit else None,
            [item.name for item in inputs], [item.name for item in outputs],
        )
        package_bytes = sum(path.stat().st_size for path in package.rglob("*") if path.is_file())
        record = {
            "name": name, "package": package.name, "layer_start": start, "layer_end": end,
            "size_bytes": package_bytes, "conversion_seconds": round(time.monotonic() - started, 3),
            "inputs": [item.name for item in inputs], "outputs": [item.name for item in outputs],
            "kv_cache_shape": list(kv_shape), "ssm_layer_indices": list(chunk.lin_layer_indices),
            "compression_audit": compression_audit,
        }
        if head_audit:
            record["head_quantization"] = head_audit
        records.append(record)
        print(f"Saved and audited {name}: {package_bytes / 1e6:.1f} MB", flush=True)
        # No disk TorchScript traces are emitted. Only these newly created
        # objects are released; no caller-owned directories are removed.
        del model, traced, chunk, examples
        gc.collect()

    return {
        "chunks": records, "context_length": context_length,
        "minimum_deployment_target": "iOS18", "requested_compute_units": "CPU_AND_NE",
        "compute_precision": "FLOAT16", "source": "calibrated_original_HF_text_weights",
        "total_model_bytes": sum(item["size_bytes"] for item in records),
        "export_seconds": round(time.monotonic() - total_started, 3),
        "compression_audit_passed": True, "device_ane_verified": False,
    }
