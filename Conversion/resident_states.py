#!/usr/bin/env python3
"""Move explicit recurrent I/O into Core ML state without changing weights.

This is a packaging transformation, not a performance or correctness test.
Device execution and numerical acceptance are performed by the user.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import shutil

from repair_tail import block_of, read_package, save_json
from optimize_body import set_name


LAYOUT = "mlkv-q4-rank4-resident-recurrent-v5"
PREFIXES = ("conv_state_", "rec_state_")


def resident_spec(original):
    spec = copy.deepcopy(original)
    function = spec.mlProgram.functions["main"]
    block = block_of(spec)
    recurrent = {item.name: copy.deepcopy(item) for item in spec.description.input
                 if item.name.startswith(PREFIXES)}
    if not recurrent:
        raise ValueError("Expected explicit recurrent inputs in the source model")
    expected_outputs = {"new_" + name for name in recurrent}
    if not expected_outputs.issubset(set(block.outputs)):
        raise ValueError("Missing recurrent output bindings")
    read_template = next(op for op in block.operations if op.type == "read_state")
    write_template = next(op for op in block.operations if op.type == "write_state")
    read_template, write_template = copy.deepcopy(read_template), copy.deepcopy(write_template)
    reads, writes, renames, records = [], [], {}, []
    function_inputs = {entry.name: entry for entry in function.inputs}
    existing = set(function_inputs) | {output.name for op in block.operations for output in op.outputs}
    for name, feature in recurrent.items():
        entry = function_inputs[name]
        tensor_type = copy.deepcopy(entry.type)
        if tensor_type.WhichOneof("type") != "tensorType":
            raise ValueError("Recurrent input must be a tensor")
        read_name = "resident_read_" + name
        if read_name in existing:
            raise ValueError("State-read name collision")
        entry.type.Clear()
        entry.type.stateType.wrappedType.CopyFrom(tensor_type)
        state = spec.description.state.add()
        state.name = name
        state.type.stateType.arrayType.CopyFrom(feature.type.multiArrayType)
        reader = copy.deepcopy(read_template)
        reader.inputs["input"].arguments[0].name = name
        del reader.outputs[:]
        output = reader.outputs.add()
        output.name = read_name
        output.type.CopyFrom(tensor_type)
        set_name(reader, read_name)
        reads.append(reader)
        renames[name] = read_name
        writer = copy.deepcopy(write_template)
        writer.inputs["input"].arguments[0].name = name
        writer.inputs["data"].arguments[0].name = "new_" + name
        set_name(writer, "resident_write_" + name)
        writes.append(writer)
        dimensions = list(feature.type.multiArrayType.shape)
        records.append({"name": name, "shape": dimensions,
                        "bytes": math.prod(dimensions) * 2})
    operations = []
    for original_op in block.operations:
        op = copy.deepcopy(original_op)
        if op.blocks:
            raise ValueError("Nested blocks are outside this transformation")
        for bindings in op.inputs.values():
            for binding in bindings.arguments:
                if binding.WhichOneof("binding") == "name" and binding.name in renames:
                    binding.name = renames[binding.name]
        operations.append(op)
    del block.operations[:]
    block.operations.extend(reads + operations + writes)
    retained_outputs = [name for name in block.outputs if name not in expected_outputs]
    del block.outputs[:]
    block.outputs.extend(retained_outputs)
    retained_inputs = [copy.deepcopy(item) for item in spec.description.input if item.name not in recurrent]
    retained_features = [copy.deepcopy(item) for item in spec.description.output if item.name not in expected_outputs]
    del spec.description.input[:]
    spec.description.input.extend(retained_inputs)
    del spec.description.output[:]
    spec.description.output.extend(retained_features)
    return spec, records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    source, destination = args.source.resolve(), args.out.resolve()
    if not source.is_dir() or destination.exists() or destination.is_relative_to(source):
        raise ValueError("Use an existing source and a new destination outside it")
    info = json.loads((source / "model-info.json").read_text(encoding="utf-8"))
    shutil.copytree(source, destination)
    chunks, bodies = {}, {}
    for suffix in "abcd":
        name = "chunk_" + suffix
        original, _ = read_package(source / (name + ".mlpackage"))
        spec, records = resident_spec(original)
        package = destination / (name + ".mlpackage")
        manifest = json.loads((package / "Manifest.json").read_text(encoding="utf-8"))
        relative = manifest["itemInfoEntries"][manifest["rootModelIdentifier"]]["path"]
        data = spec.SerializeToString()
        (package / "Data" / relative).write_bytes(data)
        bodies[name] = hashlib.sha256(data).hexdigest()
        chunks[name] = {"residentStates": records,
                        "stateBytes": sum(row["bytes"] for row in records)}
        print(name + ": moved " + str(len(records)) + " recurrent tensors to MLState", flush=True)
    source_fingerprint = info["fingerprint"]
    fingerprint = hashlib.sha256(json.dumps({"layout": LAYOUT, "source": source_fingerprint,
                                              "bodies": bodies}, sort_keys=True).encode()).hexdigest()
    state_bytes = sum(chunk["stateBytes"] for chunk in chunks.values())
    audit = {"layout": LAYOUT, "fingerprint": fingerprint, "sourceFingerprint": source_fingerprint,
             "chunks": chunks, "residentRecurrentBytes": state_bytes,
             "explicitRecurrentIOBytesRemovedPerToken": state_bytes * 2,
             "bodyProtobufSHA256": bodies, "weights": "Copied unchanged; no weight operations performed",
             "numericalTestsRun": False, "nativeCoreMLPredictValidated": False,
             "iphoneExecutionValidated": False, "latency": "Requires user device measurement"}
    save_json(destination / "resident-state-audit.json", audit)
    info.update({"name": info["name"] + " resident recurrent states", "layout": LAYOUT,
                 "fingerprint": fingerprint, "residentStateInputFingerprint": source_fingerprint,
                 "residentStateAudit": "resident-state-audit.json", "nativeCoreMLPredictValidated": False,
                 "iphoneANEExecutionValidated": False})
    for _ in range(2):
        info["bytes"] = sum(path.stat().st_size for path in destination.rglob("*") if path.is_file())
        save_json(destination / "model-info.json", info)
    print(json.dumps({"fingerprint": fingerprint, "residentRecurrentBytes": state_bytes,
                      "explicitRecurrentIOBytesRemovedPerToken": state_bytes * 2}), flush=True)


if __name__ == "__main__":
    main()
