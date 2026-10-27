#!/usr/bin/env python3
"""Split an existing quantized tail into its unchanged body and tiled heads.

No SKM, conversion passes, or requantization are run. MIL operations are copied
from the existing protobuf, and MILBlob v2 payloads are copied byte for byte.
The public storage layout is defined by Apple's coremltools 9.0
mlmodel/src/MILBlob/Blob/StorageFormat.hpp. Native Core ML load/predict and ANE
placement remain separate device/platform checks.
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
import struct
import uuid

import numpy as np
from coremltools.proto import MIL_pb2, Model_pb2


HEADER = struct.Struct("<II7Q")
SENTINEL = 0xDEADBEEF
ALIGNMENT = 64
LAYOUT = "mlkv-q4-split-head-rank4-v2"


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def file_hash(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            result.update(block)
    return result.hexdigest()


def shape(value_type):
    tensor = value_type.tensorType
    if len(tensor.dimensions) != tensor.rank:
        raise ValueError("Dynamic tensor rank is unsupported by this repair")
    dims = []
    for dim in tensor.dimensions:
        if dim.WhichOneof("dimension") != "constant":
            raise ValueError("Dynamic dimensions are unsupported by this repair")
        dims.append(int(dim.constant.size))
    return dims


def walk_messages(message):
    yield message
    for field, value in message.ListFields():
        if field.type != field.TYPE_MESSAGE:
            continue
        if field.label == field.LABEL_REPEATED:
            if field.message_type.GetOptions().map_entry:
                for nested in value.values():
                    if hasattr(nested, "ListFields"):
                        yield from walk_messages(nested)
            else:
                for nested in value:
                    yield from walk_messages(nested)
        else:
            yield from walk_messages(value)


def blob_values(message):
    for nested in walk_messages(message):
        if nested.DESCRIPTOR.full_name == MIL_pb2.Value.DESCRIPTOR.full_name:
            if nested.WhichOneof("value") == "blobFileValue":
                yield nested


def read_package(package):
    manifest = json.loads((package / "Manifest.json").read_text(encoding="utf-8"))
    path = manifest["itemInfoEntries"][manifest["rootModelIdentifier"]]["path"]
    model_path = package / "Data" / path
    spec = Model_pb2.Model()
    spec.ParseFromString(model_path.read_bytes())
    if spec.WhichOneof("Type") != "mlProgram" or list(spec.mlProgram.functions) != ["main"]:
        raise ValueError("Expected a single-function ML Program")
    return spec, model_path.parent / "weights"


def block_of(spec):
    function = spec.mlProgram.functions["main"]
    if len(function.block_specializations) != 1:
        raise ValueError("Expected exactly one block specialization")
    return function.block_specializations[function.opset]


def variable_index(block):
    result = {}
    for index, op in enumerate(block.operations):
        if op.blocks:
            raise ValueError("Nested control flow is unsupported by this targeted repair")
        for output in op.outputs:
            result[output.name] = (index, output)
    return result


def input_name(op, name):
    bindings = op.inputs[name].arguments
    if len(bindings) != 1 or bindings[0].WhichOneof("binding") != "name":
        raise ValueError(f"Expected a named input for {op.type}.{name}")
    return bindings[0].name


def input_value(block, variables, op, name):
    bindings = op.inputs[name].arguments
    if len(bindings) != 1:
        raise ValueError("Expected one compression parameter")
    binding = bindings[0]
    if binding.WhichOneof("binding") == "value":
        return binding.value
    producer = block.operations[variables[binding.name][0]]
    if producer.type != "const":
        raise ValueError("Compression parameter is not a constant")
    return producer.attributes["val"]


def inspect_tail(spec):
    block = block_of(spec)
    variables = variable_index(block)
    if spec.description.output[0].name != "logits":
        raise ValueError("Expected original full logits as the first tail output")
    logits_shape = list(spec.description.output[0].type.multiArrayType.shape)
    if logits_shape != [1, 1, 248320]:
        raise ValueError(f"Unexpected original logits shape {logits_shape}")
    last = block.operations[variables["logits"][0]]
    if last.type != "transpose":
        raise ValueError("Expected terminal logits transpose")
    conv = block.operations[variables[input_name(last, "x")][0]]
    if conv.type != "conv" or "bias" in conv.inputs:
        raise ValueError("Expected a bias-free output Conv")
    input_transpose = block.operations[variables[input_name(conv, "x")][0]]
    if input_transpose.type != "transpose":
        raise ValueError("Expected normalized hidden to Conv layout transpose")
    boundary = input_name(input_transpose, "x")
    if shape(variables[boundary][1].type) != [1, 1, 1024]:
        raise ValueError("Unexpected normalized hidden contract")
    squeezed = block.operations[variables[input_name(conv, "weight")][0]]
    if squeezed.type != "squeeze":
        raise ValueError("Expected the original 1x1 output weight squeeze")
    dequant = block.operations[variables[input_name(squeezed, "x")][0]]
    if dequant.type != "constexpr_blockwise_shift_scale" or set(dequant.inputs) != {"data", "scale"}:
        raise ValueError("Expected symmetric INT8 output-head compression")
    data = input_value(block, variables, dequant, "data")
    scale = input_value(block, variables, dequant, "scale")
    if shape(data.type) != [248320, 1024, 1, 1] or data.type.tensorType.dataType != MIL_pb2.INT8:
        raise ValueError("Unexpected head INT8 data shape or type")
    if shape(scale.type) != [248320, 1, 1, 1] or scale.type.tensorType.dataType != MIL_pb2.FLOAT16:
        raise ValueError("Unexpected head FP16 scales")
    if any(value.WhichOneof("value") != "blobFileValue" for value in (data, scale)):
        raise ValueError("Expected external head storage")
    closure = set()
    def visit(name):
        if name == boundary:
            return
        if name not in variables:
            raise ValueError(f"Unexpected external head dependency {name}")
        index = variables[name][0]
        if index in closure:
            return
        closure.add(index)
        for argument in block.operations[index].inputs.values():
            for binding in argument.arguments:
                if binding.WhichOneof("binding") == "name":
                    visit(binding.name)
    visit("logits")
    return {"boundary": boundary, "head_indices": closure, "data": data, "scale": scale}


def canonical_ops_hash(operations, reverse_name=None):
    result = hashlib.sha256()
    for original in operations:
        op = copy.deepcopy(original)
        for value in blob_values(op):
            value.blobFileValue.offset = 0
            value.blobFileValue.fileName = "@model_path/weights/weight.bin"
        if reverse_name:
            for output in op.outputs:
                if output.name == "normed_hidden":
                    output.name = reverse_name
            for argument in op.inputs.values():
                for binding in argument.arguments:
                    if binding.WhichOneof("binding") == "name" and binding.name == "normed_hidden":
                        binding.name = reverse_name
        payload = op.SerializeToString(deterministic=True)
        result.update(len(payload).to_bytes(8, "little"))
        result.update(payload)
    return result.hexdigest()


def storage_path(weights_dir, value):
    filename = value.blobFileValue.fileName
    if not filename.startswith("@model_path/weights/"):
        raise ValueError(f"Unexpected blob filename {filename}")
    relative = Path(filename.removeprefix("@model_path/weights/"))
    path = (weights_dir / relative).resolve()
    if not path.is_relative_to(weights_dir.resolve()) or not path.is_file():
        raise ValueError("Blob file escapes the source weight directory")
    return path


def blob_metadata(path, offset):
    with path.open("rb") as handle:
        storage_header = HEADER.unpack(handle.read(64))
        if storage_header[1] != 2:
            raise ValueError("Only the documented MILBlob v2 format is supported")
        if offset % 64:
            raise ValueError("Unaligned blob metadata")
        handle.seek(offset)
        fields = list(HEADER.unpack(handle.read(64)))
    if fields[0] != SENTINEL or fields[3] % 64:
        raise ValueError("Invalid blob metadata sentinel or payload alignment")
    if fields[3] + fields[2] > path.stat().st_size:
        raise ValueError("Blob payload extends outside its storage file")
    return fields


class StorageWriter:
    def __init__(self, destination):
        self.path = destination
        self.handle = destination.open("w+b")
        self.handle.write(HEADER.pack(0, 2, 0, 0, 0, 0, 0, 0, 0))
        self.records = []
        self.reused = {}

    def append(self, source, source_offset, start=0, length=None):
        metadata = blob_metadata(source, source_offset)
        available = metadata[2]
        length = available if length is None else length
        if start < 0 or length < 0 or start + length > available:
            raise ValueError("Blob byte slice is out of bounds")
        if (start != 0 or length != available) and metadata[4] != 0:
            raise ValueError("Slicing subbyte blobs is intentionally unsupported")
        key = (str(source), source_offset, start, length)
        if key in self.reused:
            return self.reused[key]
        position = self.handle.tell()
        padding = (-position) % 64
        self.handle.write(b"\x00" * padding)
        new_offset = self.handle.tell()
        copied = metadata.copy()
        copied[2], copied[3] = length, new_offset + 64
        self.handle.write(HEADER.pack(*copied))
        checksum = hashlib.sha256()
        with source.open("rb") as handle:
            handle.seek(metadata[3] + start)
            remaining = length
            while remaining:
                block = handle.read(min(remaining, 1024 * 1024))
                if not block:
                    raise IOError("Unexpected end of original blob")
                checksum.update(block)
                self.handle.write(block)
                remaining -= len(block)
        self.records.append({"source_offset": source_offset, "source_start": start,
            "new_offset": new_offset, "bytes": length, "blob_dtype": copied[1],
            "padding_bits": copied[4], "sha256": checksum.hexdigest()})
        self.reused[key] = new_offset
        return new_offset

    def finish(self):
        self.handle.seek(0)
        self.handle.write(HEADER.pack(len(self.records), 2, 0, 0, 0, 0, 0, 0, 0))
        self.handle.close()
        # Re-read all destination payloads and compare their actual hash.
        with self.path.open("rb") as handle:
            for record in self.records:
                metadata = blob_metadata(self.path, record["new_offset"])
                if metadata[1:3] != [record["blob_dtype"], record["bytes"]] or metadata[4] != record["padding_bits"]:
                    raise RuntimeError("Rewritten blob changed dtype, length, or packing")
                handle.seek(metadata[3])
                digest = hashlib.sha256()
                remaining = record["bytes"]
                while remaining:
                    block = handle.read(min(remaining, 1024 * 1024))
                    digest.update(block)
                    remaining -= len(block)
                if digest.hexdigest() != record["sha256"]:
                    raise RuntimeError("Rewritten blob payload is not byte-identical")


def new_package(path):
    root_id, weights_id = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    model_dir = path / "Data/com.apple.CoreML"
    weights_dir = model_dir / "weights"
    weights_dir.mkdir(parents=True)
    save_json(path / "Manifest.json", {"fileFormatVersion": "1.0.0", "itemInfoEntries": {
        root_id: {"author": "com.apple.CoreML", "description": "CoreML Model Specification",
                  "name": "model.mlmodel", "path": "com.apple.CoreML/model.mlmodel"},
        weights_id: {"author": "com.apple.CoreML", "description": "CoreML Model Weights",
                     "name": "weights", "path": "com.apple.CoreML/weights"}}, "rootModelIdentifier": root_id})
    return model_dir / "model.mlmodel", weights_dir


def make_body(original, tail, weights_dir, package):
    result = copy.deepcopy(original)
    source_block, target_block = block_of(original), block_of(result)
    remove = set(tail["head_indices"])
    # Keep any shared constants also consumed outside the head closure.
    changed = True
    while changed:
        changed = False
        for index, op in enumerate(source_block.operations):
            if index in remove:
                continue
            for argument in op.inputs.values():
                for binding in argument.arguments:
                    if binding.WhichOneof("binding") != "name":
                        continue
                    producer = next((i for i in remove if any(o.name == binding.name
                                    for o in source_block.operations[i].outputs)), None)
                    if producer is not None:
                        remove.remove(producer)
                        changed = True
    kept = [op for index, op in enumerate(source_block.operations) if index not in remove]
    expected_hash = canonical_ops_hash(kept)
    del target_block.operations[:]
    target_block.operations.extend(kept)
    for op in target_block.operations:
        for output in op.outputs:
            if output.name == tail["boundary"]:
                output.name = "normed_hidden"
        for argument in op.inputs.values():
            for binding in argument.arguments:
                if binding.WhichOneof("binding") == "name" and binding.name == tail["boundary"]:
                    binding.name = "normed_hidden"
    target_block.outputs[0] = "normed_hidden"
    result.description.output[0].name = "normed_hidden"
    result.description.output[0].type.multiArrayType.shape[:] = [1, 1, 1024]
    result.description.metadata.shortDescription = "Qwen3.5 calibrated tail body with normalized hidden output"
    result.description.metadata.userDefined["tail_repair_layout"] = LAYOUT
    model_path, target_weights = new_package(package)
    writer = StorageWriter(target_weights / "weight.bin")
    for value in blob_values(result):
        path = storage_path(weights_dir, value)
        value.blobFileValue.offset = writer.append(path, value.blobFileValue.offset)
        value.blobFileValue.fileName = "@model_path/weights/weight.bin"
    writer.finish()
    actual_hash = canonical_ops_hash(target_block.operations, reverse_name=tail["boundary"])
    if actual_hash != expected_hash:
        raise RuntimeError("Tail body MIL operations changed beyond the output rename/storage relocation")
    source_state_writes = sum(op.type == "write_state" for op in source_block.operations)
    target_state_writes = sum(op.type == "write_state" for op in target_block.operations)
    if source_state_writes != target_state_writes:
        raise RuntimeError("State write operations were lost")
    if any("lm_head" in output.name for op in target_block.operations for output in op.outputs):
        raise RuntimeError("An output head remained in the body")
    model_path.write_bytes(result.SerializeToString())
    return {"operation_identity_verified": True, "canonical_operations_sha256": actual_hash,
        "retained_operations": len(kept), "removed_head_operations": len(remove),
        "state_writes": target_state_writes, "weight_payload_identity_verified": True,
        "weight_payloads": writer.records,
        "palette_operators": sum(op.type == "constexpr_lut_to_dense" for op in target_block.operations)}


def resize_vocab(message, length):
    for nested in walk_messages(message):
        if nested.DESCRIPTOR.full_name == MIL_pb2.TensorType.DESCRIPTOR.full_name:
            for dimension in nested.dimensions:
                if dimension.WhichOneof("dimension") == "constant" and dimension.constant.size == 248320:
                    dimension.constant.size = length


def tensor_shape(value_type, dimensions):
    tensor = value_type.tensorType
    tensor.rank = len(dimensions)
    del tensor.dimensions[:]
    for size in dimensions:
        tensor.dimensions.add().constant.size = size


def set_int_vector(op, values):
    if op.type != "const" or op.attributes["val"].type.tensorType.dataType != MIL_pb2.INT32:
        raise ValueError("Expected a named INT32 vector constant")
    value = op.attributes["val"]
    tensor_shape(value.type, [len(values)])
    value.immediateValue.tensor.ints.values[:] = values
    tensor_shape(op.outputs[0].type, [len(values)])


def rank4_head_ops(operations, output_name, length):
    """Use an actual 2D 1x1 Conv without altering any compressed weights.

    The original export lowered Linear to rank-3 conv (Conv1D). Four-dimensional
    1x1 Conv is the layout used by Apple's ANE transformer reference. This is a
    targeted layout experiment, not evidence that Core ML will choose ANE.
    The two reshape operations only add/remove singleton dimensions, so the
    original FP16 tensor order and all dot products remain identical.
    """
    by_output = {output.name: op for op in operations for output in op.outputs}
    final = by_output[output_name]
    conv = by_output[input_name(final, "x")]
    layout_in = by_output[input_name(conv, "x")]
    squeeze = by_output[input_name(conv, "weight")]
    if final.type != "transpose" or layout_in.type != "transpose" or squeeze.type != "squeeze":
        raise ValueError("Unexpected original Conv1D head layout")
    if shape(conv.outputs[0].type) != [1, length, 1]:
        raise ValueError("Unexpected Conv1D head output shape")
    dequant = by_output[input_name(squeeze, "x")]
    if dequant.type != "constexpr_blockwise_shift_scale" or shape(dequant.outputs[0].type) != [length, 1024, 1, 1]:
        raise ValueError("Expected the original rank-4 compressed head weight")
    conv.inputs["weight"].arguments[0].name = dequant.outputs[0].name
    for layout, dimensions in ((layout_in, [1, 1024, 1, 1]), (final, [1, 1, length])):
        constant = by_output[input_name(layout, "perm")]
        set_int_vector(constant, dimensions)
        layout.type = "reshape"
        layout.inputs["shape"].CopyFrom(layout.inputs["perm"])
        del layout.inputs["perm"]
        tensor_shape(layout.outputs[0].type, dimensions)
    tensor_shape(conv.outputs[0].type, [1, length, 1, 1])
    for name, values in (("strides", [1, 1]), ("dilations", [1, 1]), ("pad", [0, 0, 0, 0])):
        set_int_vector(by_output[input_name(conv, name)], values)
    # Drop the unused weight squeeze and its now-unused axes constant. Pruning
    # from the declared output also protects against stray stale shape nodes.
    required = set()
    def visit(name):
        if name not in by_output:
            if name != "normed_hidden":
                raise ValueError(f"Unexpected external head input {name}")
            return
        op = by_output[name]
        key = op.outputs[0].name
        if key in required:
            return
        required.add(key)
        for argument in op.inputs.values():
            for binding in argument.arguments:
                if binding.WhichOneof("binding") == "name":
                    visit(binding.name)
    visit(output_name)
    return [op for op in operations if op.outputs[0].name in required]


def make_head(original, tail, weights_dir, package, tiles):
    result = copy.deepcopy(original)
    function = result.mlProgram.functions["main"]
    source_block, block = block_of(original), block_of(result)
    variables = variable_index(source_block)
    hidden_type = variables[tail["boundary"]][1].type
    del function.inputs[:]
    entry = function.inputs.add()
    entry.name = "normed_hidden"
    entry.type.CopyFrom(hidden_type)
    del result.description.input[:]
    entry = result.description.input.add()
    entry.CopyFrom(original.description.input[0])
    entry.name = "normed_hidden"
    entry.type.multiArrayType.shape[:] = [1, 1, 1024]
    del result.description.state[:]
    del result.description.output[:]
    result.description.ClearField("functions")
    del block.operations[:]
    del block.outputs[:]
    model_path, target_weights = new_package(package)
    writer = StorageWriter(target_weights / "weight.bin")
    head_ops = [source_block.operations[index] for index in sorted(tail["head_indices"])]
    source_data_key = (tail["data"].blobFileValue.fileName, tail["data"].blobFileValue.offset)
    source_scale_key = (tail["scale"].blobFileValue.fileName, tail["scale"].blobFileValue.offset)
    for tile in tiles:
        suffix = f"__tile{tile['tile']:02d}"
        names = {output.name: output.name + suffix for op in head_ops for output in op.outputs}
        names["logits"] = tile["name"]
        names[tail["boundary"]] = "normed_hidden"
        tile_operations = []
        for original_op in head_ops:
            op = copy.deepcopy(original_op)
            for output in op.outputs:
                output.name = names[output.name]
            for argument in op.inputs.values():
                for binding in argument.arguments:
                    if binding.WhichOneof("binding") == "name":
                        binding.name = names[binding.name]
            if "name" in op.attributes:
                strings = op.attributes["name"].immediateValue.tensor.strings.values
                if strings:
                    strings[0] += suffix
            resize_vocab(op, tile["length"])
            for value in blob_values(op):
                key = (value.blobFileValue.fileName, value.blobFileValue.offset)
                if key == source_data_key:
                    start, length = tile["offset"] * 1024, tile["length"] * 1024
                elif key == source_scale_key:
                    start, length = tile["offset"] * 2, tile["length"] * 2
                else:
                    raise ValueError(f"Unexpected extra head blob {key}")
                source = storage_path(weights_dir, value)
                value.blobFileValue.offset = writer.append(source, value.blobFileValue.offset, start, length)
                value.blobFileValue.fileName = "@model_path/weights/weight.bin"
            tile_operations.append(op)
        block.operations.extend(rank4_head_ops(tile_operations, tile["name"], tile["length"]))
        block.outputs.append(tile["name"])
        feature = result.description.output.add()
        feature.CopyFrom(original.description.output[0])
        feature.name = tile["name"]
        feature.type.multiArrayType.shape[:] = [1, 1, tile["length"]]
    writer.finish()
    if any(op.type == "concat" for op in block.operations):
        raise RuntimeError("Head tiling must not create an in-model concatenation")
    if any(any(dimension.constant.size == 248320 for dimension in message.dimensions)
           for message in walk_messages(result)
           if message.DESCRIPTOR.full_name == MIL_pb2.TensorType.DESCRIPTOR.full_name):
        raise RuntimeError("A full-vocabulary tensor remains in a tiled head")
    result.description.metadata.shortDescription = "Qwen3.5 exact INT8 head tiles with independent full-logit outputs"
    result.description.metadata.userDefined["tail_repair_layout"] = LAYOUT
    result.description.metadata.userDefined["tail_repair_tiles"] = json.dumps(tiles, sort_keys=True)
    model_path.write_bytes(result.SerializeToString())
    for op in block.operations:
        if op.type == "conv" and shape(op.outputs[0].type) != [1, shape(op.outputs[0].type)[1], 1, 1]:
            raise RuntimeError("Head Conv must retain rank-4 singleton-spatial layout")
    return {"outputs": tiles, "operations": len(block.operations), "conv_operators": sum(op.type == "conv" for op in block.operations),
        "conv_layout": "NCHW rank-4 1x1 Conv; compressed weights unchanged",
        "no_in_model_concat": True, "weight_payload_identity_verified": True, "weight_payloads": writer.records}


def read_blob_array(weights_dir, value):
    types = {MIL_pb2.INT8: np.dtype("i1"), MIL_pb2.FLOAT16: np.dtype("<f2")}
    dtype = types[value.type.tensorType.dataType]
    dimensions = shape(value.type)
    path = storage_path(weights_dir, value)
    fields = blob_metadata(path, value.blobFileValue.offset)
    if fields[2] != math.prod(dimensions) * dtype.itemsize or fields[4] != 0:
        raise ValueError("Unexpected byte count or padding for output-head data")
    return np.memmap(path, dtype=dtype, mode="r", offset=fields[3], shape=tuple(dimensions))


def dequantized_fp16_as_fp32(data, scales):
    result = data.reshape(data.shape[0], 1024).astype(np.float32)
    result *= scales.reshape(-1, 1).astype(np.float32)
    # The constexpr output is FP16, as in the original model. Round in row
    # blocks to avoid holding a second full-size FP16 output-head allocation.
    for start in range(0, len(result), 8192):
        result[start:start + 8192] = result[start:start + 8192].astype(np.float16)
    return result


def cpu_equivalence(original, tail, weights_dir, destination, head_models, samples):
    original_data = read_blob_array(weights_dir, tail["data"])
    original_scale = read_blob_array(weights_dir, tail["scale"])
    rng = np.random.default_rng(20261028)
    hidden = rng.normal(size=(samples, 1024)).astype(np.float16)
    original_weights = dequantized_fp16_as_fp32(original_data, original_scale)
    reference = original_weights @ hidden.astype(np.float32).T
    del original_weights
    assembled = np.empty_like(reference)
    tiles_verified = 0
    for model_info in head_models:
        spec, local_weights = read_package(destination / (model_info["name"] + ".mlpackage"))
        quant_ops = [op for op in block_of(spec).operations if op.type == "constexpr_blockwise_shift_scale"]
        if len(quant_ops) != len(model_info["outputs"]):
            raise RuntimeError("Head model's output count does not match its INT8 blocks")
        index = variable_index(block_of(spec))
        for output, op in zip(model_info["outputs"], quant_ops, strict=True):
            data = read_blob_array(local_weights, input_value(block_of(spec), index, op, "data"))
            scales = read_blob_array(local_weights, input_value(block_of(spec), index, op, "scale"))
            start, stop = output["offset"], output["offset"] + output["length"]
            if not np.array_equal(data, original_data[start:stop]) or not np.array_equal(scales, original_scale[start:stop]):
                raise RuntimeError("Head tiling changed INT8 data or FP16 scales")
            weights = dequantized_fp16_as_fp32(data, scales)
            assembled[start:stop] = weights @ hidden.astype(np.float32).T
            tiles_verified += 1
    if not np.isfinite(reference).all() or not np.isfinite(assembled).all():
        raise RuntimeError("Non-finite CPU output-head equivalence fixture")
    difference = assembled - reference
    max_abs = float(np.max(np.abs(difference)))
    relative_l2 = float(np.linalg.norm(difference) / max(np.linalg.norm(reference), 1e-20))
    equal_top1 = np.array_equal(reference.argmax(axis=0), assembled.argmax(axis=0))
    if relative_l2 > 2e-6 or max_abs > 2e-4 or not equal_top1:
        raise RuntimeError(f"CPU output-head equivalence failed: {max_abs=}, {relative_l2=}, {equal_top1=}")
    np.savez(destination / "cpu-head-fixtures.npz", normed_hidden=hidden.reshape(samples, 1, 1, 1024),
             full_logits=reference.T.copy(), source_fingerprint=np.array(json.loads((destination / "source-model-info.json").read_text())["fingerprint"]))
    return {"passed": True, "samples": samples, "seed": 20261028, "vocabulary": 248320,
        "tiles_verified": tiles_verified, "all_int8_data_and_fp16_scales_identical": True,
        "reference": "original full INT8 head -> FP16 dequantized weights -> FP32 CPU matmul",
        "comparison": "new package INT8 tiles -> FP16 dequantized weights -> FP32 CPU matmul -> CPU assembly",
        "max_abs_error": max_abs, "relative_l2_error": relative_l2, "all_top1_equal": bool(equal_top1),
        "native_coreml_predict_verified": False, "iphone_ane_execution_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--head-rows", type=int, default=8192)
    parser.add_argument("--tiles-per-model", type=int, default=8)
    parser.add_argument("--cpu-samples", type=int, default=3)
    parser.add_argument("--skip-numerical-tests", action="store_true")
    args = parser.parse_args()
    source, destination = args.source.resolve(), args.out.resolve()
    if destination.exists() or source == destination or destination.is_relative_to(source):
        raise ValueError("Use a new destination outside the original model directory")
    if not 32 <= args.head_rows <= 16384 or args.head_rows % 32:
        raise ValueError("head-rows must be a multiple of 32 within 32..16384")
    if not 1 <= args.tiles_per_model <= 16 or not 1 <= args.cpu_samples <= 8:
        raise ValueError("Invalid model tile count or CPU fixture count")
    original, weights_dir = read_package(source / "chunk_d.mlpackage")
    tail = inspect_tail(original)
    source_info = json.loads((source / "model-info.json").read_text(encoding="utf-8"))
    destination.mkdir(parents=True)
    save_json(destination / "source-model-info.json", source_info)
    for name in ("chunk_a.mlpackage", "chunk_b.mlpackage", "chunk_c.mlpackage"):
        shutil.copytree(source / name, destination / name)
    for name in ("embed_weight.int8.bin", "quantization-quality.json"):
        shutil.copy2(source / name, destination / name)
    body_audit = make_body(original, tail, weights_dir, destination / "chunk_d.mlpackage")
    print(f"Tail body: {body_audit['retained_operations']} original operations preserved; byte-identical packed weights", flush=True)
    tiles = [{"tile": index, "name": f"logits_{index:02d}", "offset": start, "length": min(args.head_rows, 248320 - start)}
             for index, start in enumerate(range(0, 248320, args.head_rows))]
    head_models, head_audits = [], []
    for model_index, start in enumerate(range(0, len(tiles), args.tiles_per_model)):
        group = tiles[start:start + args.tiles_per_model]
        name = f"head_{model_index}"
        audit = make_head(original, tail, weights_dir, destination / (name + ".mlpackage"), group)
        head_models.append({"name": name, "outputs": [{key: tile[key] for key in ("name", "offset", "length")} for tile in group]})
        head_audits.append({"name": name, **audit})
        print(f"Head {name}: {len(group)} independent Conv outputs, {sum(tile['length'] for tile in group)} vocabulary rows", flush=True)
    coverage = np.zeros(248320, dtype=np.uint8)
    for tile in tiles:
        coverage[tile["offset"]:tile["offset"] + tile["length"]] += 1
    if not np.all(coverage == 1):
        raise RuntimeError("Tiled output does not cover every original vocabulary row exactly once")
    equivalence = ({"passed": None, "skipped": True, "reason": "All tests are performed by the user"}
                   if args.skip_numerical_tests else
                   cpu_equivalence(original, tail, weights_dir, destination, head_models, args.cpu_samples))
    save_json(destination / "cpu-head-equivalence.json", equivalence)
    inventory = {str(path.relative_to(destination)): file_hash(path)
                 for package in sorted(destination.glob("*.mlpackage"))
                 for path in sorted(package.rglob("*")) if path.is_file()}
    for name in ("chunk_a.mlpackage", "chunk_b.mlpackage", "chunk_c.mlpackage"):
        for relative, digest in inventory.items():
            if relative.startswith(name + "/") and file_hash(source / relative) != digest:
                raise RuntimeError(f"Unchanged body package is not identical: {relative}")
    fingerprint = hashlib.sha256(json.dumps({"layout": LAYOUT, "source": source_info["fingerprint"],
        "files": inventory, "headModels": head_models}, sort_keys=True).encode()).hexdigest()
    repaired_info = dict(source_info)
    repaired_info.update({"name": source_info["name"] + " split output heads", "fingerprint": fingerprint,
        "sourceFingerprint": source_info["fingerprint"], "layout": LAYOUT,
        "bodyOutput": "normed_hidden", "headInput": "normed_hidden", "headModels": head_models,
        "iphoneANEExecutionValidated": False, "nativeCoreMLPredictValidated": False,
        "bytes": sum(path.stat().st_size for path in destination.rglob("*") if path.is_file())})
    save_json(destination / "model-info.json", repaired_info)
    save_json(destination / "tail-repair-audit.json", {"layout": LAYOUT, "fingerprint": fingerprint,
        "sourceFingerprint": source_info["fingerprint"], "unchanged_a_b_c_verified": True,
        "body": body_audit, "heads": head_audits, "full_vocabulary_coverage": True,
        "cpu_equivalence": equivalence, "filesSHA256": inventory,
        "root_cause": "Original full output projection split into tiles; rank-3 Conv1D head replaced by rank-4 Conv2D as an ANE layout experiment. Native/device validation is still required."})
    if (source / "coreml-export.json").is_file():
        export = json.loads((source / "coreml-export.json").read_text(encoding="utf-8"))
        for chunk in export.get("chunks", []):
            if chunk["name"] == "chunk_d":
                chunk["outputs"][0] = "normed_hidden"
                chunk["size_bytes"] = sum(path.stat().st_size for path in (destination / "chunk_d.mlpackage").rglob("*") if path.is_file())
                chunk["original_fused_tail_audit"] = chunk.pop("compression_audit", None)
                if "head_quantization" in chunk:
                    chunk["original_fused_tail_head_quantization"] = chunk.pop("head_quantization")
                chunk["tail_repair_audit"] = "tail-repair-audit.json"
        export.update({"layout": LAYOUT, "headModels": head_models, "device_ane_verified": False,
            "total_model_bytes": sum(path.stat().st_size for package in destination.glob("*.mlpackage")
                                     for path in package.rglob("*") if path.is_file())})
        save_json(destination / "coreml-export.json", export)
    # Include the completed audit/export/fixture files in bundle storage size.
    # The second pass also accounts for a possible decimal-width change in this
    # very field without changing the model-content cache fingerprint.
    for _ in range(2):
        repaired_info["bytes"] = sum(path.stat().st_size for path in destination.rglob("*") if path.is_file())
        save_json(destination / "model-info.json", repaired_info)
    print("REPAIR READY " + json.dumps({"fingerprint": fingerprint, "bodyOutput": "normed_hidden",
        "headModels": len(head_models), "tiles": len(tiles), "cpu_equivalence": equivalence}), flush=True)


if __name__ == "__main__":
    main()
