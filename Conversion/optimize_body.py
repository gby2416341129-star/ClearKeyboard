#!/usr/bin/env python3
"""Restore rank-4 1x1 body projections without converting or changing weights.

The baseline is an already calibrated, split-head ML Program bundle. This tool
only rewrites static layouts around Conv1D projections. It does not quantize,
retrain, change vocabulary, alter state updates, or invoke conversion passes.
Native Core ML correctness, hardware placement and speed require device checks.
"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import json
import math
from pathlib import Path
import shutil

import numpy as np
from coremltools.proto import MIL_pb2

from repair_tail import (block_of, file_hash, input_name, input_value,
                         read_package, save_json, shape, tensor_shape,
                         variable_index)


LAYOUT = "mlkv-q4-body-rank4-split-head-v4"


def digest(message):
    return hashlib.sha256(message.SerializeToString(deterministic=True)).hexdigest()


def set_name(op, name):
    value = op.attributes["name"]
    value.type.tensorType.dataType = MIL_pb2.STRING
    value.type.tensorType.rank = 0
    value.immediateValue.tensor.strings.values[:] = [name]


def make_int_const(name, values):
    op = MIL_pb2.Operation(type="const")
    output = op.outputs.add()
    output.name = name
    output.type.tensorType.dataType = MIL_pb2.INT32
    tensor_shape(output.type, [len(values)])
    value = op.attributes["val"]
    value.type.CopyFrom(output.type)
    value.immediateValue.tensor.ints.values[:] = values
    set_name(op, name)
    return op


def make_reshape(name, source, source_type, dimensions, shape_name):
    op = MIL_pb2.Operation(type="reshape")
    op.inputs["x"].arguments.add().name = source
    op.inputs["shape"].arguments.add().name = shape_name
    output = op.outputs.add()
    output.name = name
    output.type.CopyFrom(source_type)
    tensor_shape(output.type, dimensions)
    set_name(op, name)
    return op


def const_ints(block, variables, op, key):
    value = input_value(block, variables, op, key)
    if value.type.tensorType.dataType != MIL_pb2.INT32:
        raise ValueError(f"Expected INT32 parameter {key}")
    return list(value.immediateValue.tensor.ints.values)


def interface_digest(spec):
    return digest(spec.description)


def validate_topology(spec):
    function = spec.mlProgram.functions["main"]
    block = block_of(spec)
    available = {value.name for value in function.inputs}
    if len(available) != len(function.inputs):
        raise ValueError("Duplicate function inputs")
    for op in block.operations:
        if op.blocks:
            raise ValueError("Nested blocks are outside this targeted optimization")
        for bindings in op.inputs.values():
            for binding in bindings.arguments:
                if binding.WhichOneof("binding") == "name" and binding.name not in available:
                    raise ValueError(f"Unresolved or forward dependency: {op.type} -> {binding.name}")
        for output in op.outputs:
            if output.name in available:
                raise ValueError(f"Duplicate SSA name {output.name}")
            available.add(output.name)
    if set(block.outputs) - available:
        raise ValueError("Unresolved public block outputs")
    return {"passed": True, "operations": len(block.operations),
            "stateful_operations": dict(Counter(op.type for op in block.operations
                if op.type in ("read_state", "write_state", "coreml_update_state")))}


def optimize_spec(original):
    result = copy.deepcopy(original)
    source_block, block = block_of(original), block_of(result)
    variables = variable_index(source_block)
    function_types = {entry.name: entry.type for entry in original.mlProgram.functions["main"].inputs}
    existing = set(variables) | set(function_types)
    inserted = set()
    operation_list, records, skipped = [], [], []
    input_layouts, weight_layouts = {}, {}

    def unique(base):
        if base in existing or base in inserted:
            raise ValueError(f"Unexpected optimizer name collision: {base}")
        inserted.add(base)
        return base

    def append(op):
        operation_list.append(op)

    def int_const(base, values):
        name = unique(base)
        append(make_int_const(name, values))
        return name

    def value_type(name):
        return variables[name][1].type if name in variables else function_types[name]

    for original_op in source_block.operations:
        if original_op.type != "conv":
            append(copy.deepcopy(original_op))
            continue
        output = original_op.outputs[0]
        x_name, weight_name = input_name(original_op, "x"), input_name(original_op, "weight")
        x_shape, weight_shape, y_shape = shape(value_type(x_name)), shape(value_type(weight_name)), shape(output.type)
        if len(x_shape) != 3 or len(weight_shape) != 3 or weight_shape[-1] != 1:
            skipped.append({"output": output.name, "input": x_shape, "weight": weight_shape,
                            "reason": "Only static rank-3 1x1 projections are targeted"})
            append(copy.deepcopy(original_op))
            continue
        strides = const_ints(source_block, variables, original_op, "strides")
        dilations = const_ints(source_block, variables, original_op, "dilations")
        pad = const_ints(source_block, variables, original_op, "pad")
        groups = const_ints(source_block, variables, original_op, "groups")
        pad_type = list(input_value(source_block, variables, original_op, "pad_type").immediateValue.tensor.strings.values)
        if strides != [1] or dilations != [1] or pad != [0, 0] or groups != [1] or pad_type != ["valid"]:
            raise ValueError(f"Unexpected parameters for targeted projection: {output.name}")
        if x_shape[1] != weight_shape[1] or y_shape != [x_shape[0], weight_shape[0], x_shape[2]]:
            raise ValueError(f"Unexpected projection shape: {output.name}")
        base = output.name + "__body4d"
        if x_name not in input_layouts:
            x4 = unique(x_name + "__body4d_input")
            dimensions = [x_shape[0], x_shape[1], 1, x_shape[2]]
            parameter = int_const(x4 + "_shape", dimensions)
            append(make_reshape(x4, x_name, value_type(x_name), dimensions, parameter))
            input_layouts[x_name] = x4
        x4 = input_layouts[x_name]
        if weight_name not in weight_layouts:
            producer = source_block.operations[variables[weight_name][0]]
            dimensions = [weight_shape[0], weight_shape[1], 1, 1]
            if producer.type == "squeeze":
                upstream = input_name(producer, "x")
                if shape(value_type(upstream)) != dimensions:
                    raise ValueError(f"Compressed source weight is not rank-4 1x1: {weight_name}")
                # A squeeze only removes singleton axes; restoring those axes
                # changes neither the constexpr precision nor element order.
                w4, mode = upstream, "bypass_original_rank4_weight_squeeze"
            elif producer.type == "const":
                # Duplicate only the constant descriptor and blob reference.
                # The underlying file, offset, payload and FP16 values stay exact.
                new_const = copy.deepcopy(producer)
                w4 = unique(weight_name + "__body4d_weight")
                new_const.outputs[0].name = w4
                tensor_shape(new_const.outputs[0].type, dimensions)
                tensor_shape(new_const.attributes["val"].type, dimensions)
                set_name(new_const, w4)
                append(new_const)
                mode = "rank4_const_descriptor_same_payload"
            else:
                raise ValueError(f"Unexpected weight producer {producer.type}: {weight_name}")
            weight_layouts[weight_name] = (w4, mode)
        w4, weight_mode = weight_layouts[weight_name]
        conv = copy.deepcopy(original_op)
        for key, value in (("x", x4), ("weight", w4)):
            conv.inputs[key].arguments[0].name = value
        for key, values in (("strides", [1, 1]), ("dilations", [1, 1]), ("pad", [0, 0, 0, 0])):
            conv.inputs[key].arguments[0].name = int_const(base + "_" + key, values)
        conv_output = unique(base + "_conv")
        conv.outputs[0].name = conv_output
        tensor_shape(conv.outputs[0].type, [y_shape[0], y_shape[1], 1, y_shape[2]])
        set_name(conv, conv_output)
        append(conv)
        parameter = int_const(base + "_output_shape", y_shape)
        # Preserve the exact original output name and type for every consumer,
        # including SSM recurrence, attention and state update operations.
        append(make_reshape(output.name, conv_output, output.type, y_shape, parameter))
        records.append({"originalOutput": output.name, "newConvOutput": conv_output,
                        "inputShape": x_shape, "weightShape": weight_shape, "outputShape": y_shape,
                        "rank4Input": [x_shape[0], x_shape[1], 1, x_shape[2]],
                        "rank4Weight": [weight_shape[0], weight_shape[1], 1, 1],
                        "weightMode": weight_mode, "originalConvSHA256": digest(original_op),
                        "biasPreserved": "bias" in original_op.inputs})
    if not records:
        raise ValueError("No eligible body projections found")
    del block.operations[:]
    block.operations.extend(operation_list)
    if interface_digest(result) != interface_digest(original):
        raise RuntimeError("Public model inputs, outputs or state contracts changed")
    original_non_conv = [digest(op) for op in source_block.operations if op.type != "conv"]
    retained_non_conv = [digest(op) for op in block.operations
                         if op.type != "conv" and not any(output.name in inserted for output in op.outputs)
                         and not any(output.name == record["originalOutput"] for output in op.outputs for record in records)]
    if original_non_conv != retained_non_conv:
        raise RuntimeError("An original non-Conv operation changed or moved")
    for record in records:
        old = variables[record["originalOutput"]][1]
        new = variable_index(block)[record["originalOutput"]][1]
        if old.type.SerializeToString(deterministic=True) != new.type.SerializeToString(deterministic=True):
            raise RuntimeError("An original Conv consumer contract changed")
    old_compression = [digest(op) for op in source_block.operations if op.type.startswith("constexpr_")]
    new_compression = [digest(op) for op in block.operations if op.type.startswith("constexpr_")]
    if old_compression != new_compression:
        raise RuntimeError("A compression operation or LUT reference changed")
    topology = validate_topology(result)
    result.description.metadata.userDefined["body_rank4_layout"] = LAYOUT
    return result, {"convertedConv1DCount": len(records), "skipped": skipped,
                    "sharedInputLayouts": len(input_layouts), "weightModes": dict(Counter(r["weightMode"] for r in records)),
                    "originalNonConvOperationsByteIdentical": True, "compressionOperationsByteIdentical": True,
                    "publicInterfaceByteIdentical": True, "originalConvOutputsSameNamesAndTypes": True,
                    "topology": topology, "projections": records}


def numpy_equivalence(projections):
    """Independent static-layout algebra check; not Core ML execution evidence."""
    rng = np.random.default_rng(20261027)
    unique_shapes = sorted({tuple(record["weightShape"]) for record in projections})
    results = []
    for out_channels, in_channels, kernel in unique_shapes:
        # Real projection channel dimensions, with multiple positions to catch
        # wrong axes even though the shipping decode graph has L=1.
        x = rng.normal(size=(1, in_channels, 3)).astype(np.float16).astype(np.float64)
        w = (rng.normal(size=(out_channels, in_channels, kernel)) / math.sqrt(in_channels)).astype(np.float16).astype(np.float64)
        bias = rng.normal(size=out_channels).astype(np.float16).astype(np.float64)
        reference = np.einsum("ncl,oc->nol", x, w[:, :, 0], optimize=False)
        reference += bias[None, :, None]
        x4, w4 = x.reshape(1, in_channels, 1, 3), w.reshape(out_channels, in_channels, 1, 1)
        actual = np.tensordot(x4, w4[:, :, 0, 0], axes=([1], [1])).transpose(0, 3, 1, 2)
        actual += bias[None, :, None, None]
        actual = actual.reshape(reference.shape)
        max_abs = float(np.max(np.abs(reference - actual)))
        if max_abs > 1e-10 or not np.array_equal(reference.astype(np.float16), actual.astype(np.float16)):
            raise RuntimeError(f"Rank-4 Conv numerical layout check failed: {max_abs}")
        results.append({"weightShape": [out_channels, in_channels, kernel], "positions": 3,
                        "maxAbsFloat64Error": max_abs, "fp16OutputsExactlyEqual": True})
    return {"passed": True, "seed": 20261027, "projectionShapes": results,
            "scope": "Independent NumPy Conv1D/Conv2D algebra with synthetic FP16-rounded data at all actual channel shapes; not native Core ML execution",
            "nativeCoreMLPredictVerified": False, "iphoneExecutionVerified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--skip-numerical-tests", action="store_true")
    args = parser.parse_args()
    source, destination = args.source.resolve(), args.out.resolve()
    if not source.is_dir() or destination.exists() or source == destination or destination.is_relative_to(source):
        raise ValueError("Use an existing source and a new destination outside it")
    source_info = json.loads((source / "model-info.json").read_text(encoding="utf-8"))
    if not source_info.get("headModels") or source_info.get("bodyOutput") != "normed_hidden":
        raise ValueError("Expected a previously validated split-head model contract")
    shutil.copytree(source, destination)
    chunks, all_projections = {}, []
    for suffix in "abcd":
        name = f"chunk_{suffix}"
        spec, _ = read_package(source / (name + ".mlpackage"))
        optimized, audit = optimize_spec(spec)
        package = destination / (name + ".mlpackage")
        manifest = json.loads((package / "Manifest.json").read_text(encoding="utf-8"))
        path = manifest["itemInfoEntries"][manifest["rootModelIdentifier"]]["path"]
        (package / "Data" / path).write_bytes(optimized.SerializeToString())
        chunks[name] = audit
        all_projections.extend(audit["projections"])
        print(f"{name}: {audit['convertedConv1DCount']} rank-4 projections, unchanged compression/state contracts", flush=True)
    numeric = ({"passed": None, "skipped": True, "reason": "All tests are performed by the user"}
               if args.skip_numerical_tests else numpy_equivalence(all_projections))
    weights = {}
    # Hash the complete files, not only used blob slices: all calibrated LUTs,
    # indices, scales, floating gate constants and the embedding stay exact.
    for package in sorted(source.glob("*.mlpackage")):
        for path in sorted(package.rglob("*")):
            if not path.is_file() or "weights" not in path.relative_to(package).parts:
                continue
            relative = path.relative_to(source).as_posix()
            before, after = file_hash(path), file_hash(destination / relative)
            if before != after:
                raise RuntimeError(f"Weight file changed: {relative}")
            weights[relative] = before
    embedding = source_info["embeddingFile"]
    embedding_hash = file_hash(source / embedding)
    if embedding_hash != file_hash(destination / embedding):
        raise RuntimeError("Embedding changed")
    head_files = {}
    for head in source_info["headModels"]:
        for path in sorted((source / (head["name"] + ".mlpackage")).rglob("*")):
            if path.is_file():
                relative = path.relative_to(source).as_posix()
                head_files[relative] = file_hash(path)
                if head_files[relative] != file_hash(destination / relative):
                    raise RuntimeError(f"An original output-head file changed: {relative}")
    inventory = {path.relative_to(destination).as_posix(): file_hash(path)
                 for package in sorted(destination.glob("*.mlpackage"))
                 for path in sorted(package.rglob("*")) if path.is_file()}
    fingerprint = hashlib.sha256(json.dumps({"layout": LAYOUT, "source": source_info["fingerprint"],
                                            "files": inventory}, sort_keys=True).encode()).hexdigest()
    audit = {"layout": LAYOUT, "fingerprint": fingerprint, "sourceFingerprint": source_info["fingerprint"],
             "bodyInputFingerprint": source_info["fingerprint"], "chunks": chunks,
             "convertedProjectionCount": len(all_projections), "allWeightFilesByteIdentical": True,
             "weightFilesSHA256": weights, "embeddingSHA256": embedding_hash,
             "allHeadPackageFilesByteIdentical": True, "headFilesSHA256": head_files,
             "numpyLayoutEquivalence": numeric, "modelFilesSHA256": inventory,
             "nativeCoreMLPredictValidated": False, "iphoneANEExecutionValidated": False,
             "hardwarePlacementAndLatency": "Unknown until new native/device validation; layout experiment does not assert ANE support or speedup",
             "aneCode34RootCause": "Not established; this rewrite targets dense-projection layout and does not prove or claim a fix for the original ANE runtime error"}
    save_json(destination / "body-optimization-audit.json", audit)
    save_json(destination / "body-input-model-info.json", source_info)
    info = dict(source_info)
    info.update({"name": source_info["name"] + " rank-4 body projections", "fingerprint": fingerprint,
                 "sourceFingerprint": source_info["fingerprint"], "bodyInputFingerprint": source_info["fingerprint"],
                 "layout": LAYOUT, "nativeCoreMLPredictValidated": False, "iphoneANEExecutionValidated": False,
                 "bodyOptimizationAudit": "body-optimization-audit.json"})
    for _ in range(3):
        info["bytes"] = sum(path.stat().st_size for path in destination.rglob("*") if path.is_file())
        save_json(destination / "model-info.json", info)
    if (destination / "coreml-export.json").exists():
        export = json.loads((destination / "coreml-export.json").read_text(encoding="utf-8"))
        export.update({"layout": LAYOUT, "bodyOptimizationAudit": "body-optimization-audit.json",
                       "device_ane_verified": False, "native_coreml_predict_verified": False})
        save_json(destination / "coreml-export.json", export)
        for _ in range(2):
            info["bytes"] = sum(path.stat().st_size for path in destination.rglob("*") if path.is_file())
            save_json(destination / "model-info.json", info)
    print("BODY OPTIMIZATION READY " + json.dumps({"fingerprint": fingerprint,
        "convertedProjections": len(all_projections), "allWeightFilesByteIdentical": True,
        "numpyLayoutEquivalencePassed": numeric["passed"], "nativeAndDeviceValidationRequired": True}), flush=True)


if __name__ == "__main__":
    main()
