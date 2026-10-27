#!/usr/bin/env python3
"""Pack recurrent buffers into the body's existing single rank-4 MLState.

Build 5's separate state-input design failed on the user's iPhone ANE path.
This alternative keeps one state input and one end-of-call state write. It is
an unverified device experiment, not a claimed fix for the opaque -14 error.
"""
from __future__ import annotations

import copy
import math

from coremltools.proto import MIL_pb2
from repair_tail import block_of, input_name, tensor_shape
from optimize_body import make_int_const, make_reshape, set_name
from resident_states import main as package_model


LAYOUT = "mlkv-q4-rank4-single-packed-state-v6"
PREFIXES = ("conv_state_", "rec_state_")
PAGE = 4 * 256


def packed_spec(original):
    spec = copy.deepcopy(original)
    function, block = spec.mlProgram.functions["main"], block_of(spec)
    recurrent = {x.name: copy.deepcopy(x) for x in spec.description.input if x.name.startswith(PREFIXES)}
    if not recurrent or [x.name for x in spec.description.state] != ["kv_cache"]:
        raise ValueError("Source must be the Build 4 body with one KV state and explicit recurrent I/O")
    old_ops = [copy.deepcopy(op) for op in block.operations]
    del block.operations[:]
    entry = next(x for x in function.inputs if x.name == "kv_cache")
    kv_type = copy.deepcopy(entry.type.stateType.wrappedType)
    kv_shape = [int(d.constant.size) for d in kv_type.tensorType.dimensions]
    kv_elements = math.prod(kv_shape)
    if kv_elements % PAGE:
        raise ValueError("KV storage is not page aligned")
    records, cursor = [], kv_elements // PAGE
    for name, feature in recurrent.items():
        dimensions = list(feature.type.multiArrayType.shape)
        elements = math.prod(dimensions)
        if elements % PAGE:
            raise ValueError("Recurrent storage is not page aligned")
        records.append({"name": name, "shape": dimensions, "bytes": elements * 2,
                        "packedOffset": cursor, "packedHeight": elements // PAGE})
        cursor += elements // PAGE
    packed_shape = [1, 4, cursor, 256]
    packed_type = copy.deepcopy(kv_type)
    tensor_shape(packed_type, packed_shape)
    for record in records:
        record["packedBufferShape"] = packed_shape
    entry.type.stateType.wrappedType.CopyFrom(packed_type)
    state_array = spec.description.state[0].type.stateType.arrayType
    del state_array.shape[:]
    state_array.shape.extend(packed_shape)
    inputs = [copy.deepcopy(x) for x in function.inputs if x.name not in recurrent]
    del function.inputs[:]
    function.inputs.extend(inputs)
    retained = [copy.deepcopy(x) for x in spec.description.input if x.name not in recurrent]
    del spec.description.input[:]
    spec.description.input.extend(retained)
    removed = {"new_" + name for name in recurrent}
    retained = [copy.deepcopy(x) for x in spec.description.output if x.name not in removed]
    del spec.description.output[:]
    spec.description.output.extend(retained)
    outputs = [name for name in block.outputs if name not in removed]
    del block.outputs[:]
    block.outputs.extend(outputs)
    read_template = copy.deepcopy(next(op for op in old_ops if op.type == "read_state"))
    write_template = copy.deepcopy(next(op for op in old_ops if op.type == "write_state"))
    existing = {x.name for x in function.inputs} | {v.name for op in old_ops for v in op.outputs}

    def append(op):
        block.operations.add().CopyFrom(op)

    def fresh(name):
        name = "single_state_" + name
        if name in existing:
            raise ValueError("Packed-state SSA name collision")
        existing.add(name)
        return name

    def ints(name, values):
        name = fresh(name)
        append(make_int_const(name, values))
        return name

    def reshape(name, value, value_type, dimensions, output_name=None):
        shape_name = ints(name + "_shape", dimensions)
        output = output_name or fresh(name)
        append(make_reshape(output, value, value_type, dimensions, shape_name))
        return output

    reader = copy.deepcopy(read_template)
    base_name = fresh("buffer")
    reader.outputs[0].name = base_name
    reader.outputs[0].type.CopyFrom(packed_type)
    set_name(reader, base_name)
    append(reader)

    def unpack(name, offset, height, dimensions, tensor_type):
        begin = ints(name + "_begin", [0, 0, offset, 0])
        end = ints(name + "_end", [1, 4, offset + height, 256])
        out_name = fresh(name + "_slice")
        op = MIL_pb2.Operation(type="slice_by_index")
        for key, value in [("x", base_name), ("begin", begin), ("end", end)]:
            op.inputs[key].arguments.add().name = value
        out = op.outputs.add()
        out.name = out_name
        out.type.CopyFrom(packed_type)
        tensor_shape(out.type, [1, 4, height, 256])
        set_name(op, out_name)
        append(op)
        return reshape(name + "_unpack", out_name, out.type, dimensions)

    current_kv = unpack("kv", 0, kv_elements // PAGE, kv_shape, kv_type)
    recurrent_types = {x.name: copy.deepcopy(x.type) for x in original.mlProgram.functions["main"].inputs
                       if x.name in recurrent}
    renames = {}
    for record in records:
        name = record["name"]
        renames[name] = unpack(name, record["packedOffset"], record["packedHeight"],
                               record["shape"], recurrent_types[name])
    writes = 0
    for op in old_ops:
        if op.blocks:
            raise ValueError("Nested blocks are outside this transformation")
        if op.type == "read_state":
            if input_name(op, "input") != "kv_cache":
                raise ValueError("Unexpected source state")
            # Preserve sequential KV semantics using the most recent SSA value.
            reshape("kv_alias_" + str(writes) + "_" + op.outputs[0].name,
                    current_kv, kv_type, kv_shape, output_name=op.outputs[0].name)
            continue
        if op.type == "write_state":
            if input_name(op, "input") != "kv_cache":
                raise ValueError("Unexpected source state")
            current_kv = input_name(op, "data")
            writes += 1
            continue
        for bindings in op.inputs.values():
            for binding in bindings.arguments:
                if binding.WhichOneof("binding") == "name" and binding.name in renames:
                    binding.name = renames[binding.name]
        append(op)
    if not writes:
        raise ValueError("Missing original KV updates")
    pieces = [reshape("kv_pack", current_kv, kv_type, [1, 4, kv_elements // PAGE, 256])]
    for record in records:
        name = record["name"]
        pieces.append(reshape(name + "_pack", "new_" + name, recurrent_types[name],
                              [1, 4, record["packedHeight"], 256]))
    axis = make_int_const(fresh("axis"), [2])
    tensor_shape(axis.outputs[0].type, [])
    axis.attributes["val"].type.CopyFrom(axis.outputs[0].type)
    append(axis)
    result_name = fresh("next_buffer")
    concat = MIL_pb2.Operation(type="concat")
    for value in pieces:
        concat.inputs["values"].arguments.add().name = value
    concat.inputs["axis"].arguments.add().name = axis.outputs[0].name
    out = concat.outputs.add()
    out.name = result_name
    out.type.CopyFrom(packed_type)
    set_name(concat, result_name)
    append(concat)
    writer = copy.deepcopy(write_template)
    writer.inputs["data"].arguments[0].name = result_name
    set_name(writer, fresh("commit"))
    append(writer)
    return spec, records


if __name__ == "__main__":
    package_model(transform=packed_spec, layout=LAYOUT, audit_file="packed-state-audit.json")
