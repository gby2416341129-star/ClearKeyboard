#!/usr/bin/env python3
"""Validate downloaded protobuf contracts without executing Core ML.

Mac: pip install coremltools==9.0
Windows: --schema-wheel accepts the official coremltools wheel for its Python
protobuf schema only. This does not load or emulate Apple's Core ML runtime.
"""
import argparse
import json
from pathlib import Path
import sys
import tempfile
import types
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema-wheel", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        if args.schema_wheel:
            with zipfile.ZipFile(args.schema_wheel) as archive:
                for item in archive.namelist():
                    if item.startswith("coremltools/proto/") and ".." not in Path(item).parts:
                        archive.extract(item, temporary)
            package = types.ModuleType("coremltools")
            package.__path__ = [str(Path(temporary) / "coremltools")]
            sys.modules["coremltools"] = package
        from coremltools.proto import Model_pb2, FeatureTypes_pb2
        lock = json.loads((ROOT / "model.lock.json").read_text())
        result = {}
        for suffix in "abcd":
            name = f"chunk_{suffix}.mlpackage"
            path = ROOT / "Models" / lock["bundle"] / name / "Data/com.apple.CoreML/model.mlmodel"
            spec = Model_pb2.Model()
            spec.ParseFromString(path.read_bytes())
            contract = {"specificationVersion": spec.specificationVersion,
                        "functions": list(spec.mlProgram.functions),
                        "inputs": [], "outputs": [], "states": []}
            for group, features in (("inputs", spec.description.input),
                                    ("outputs", spec.description.output),
                                    ("states", spec.description.state)):
                for feature in features:
                    kind = feature.type.WhichOneof("Type")
                    array = (feature.type.stateType.arrayType if kind == "stateType"
                             else feature.type.multiArrayType)
                    contract[group].append({"name": feature.name, "shape": list(array.shape),
                        "dtype": FeatureTypes_pb2.ArrayFeatureType.ArrayDataType.Name(array.dataType)})
            inputs = {f["name"]: f for f in contract["inputs"]}
            outputs = {f["name"]: f for f in contract["outputs"]}
            assert spec.specificationVersion == 9 and contract["functions"] == ["main"], name
            for key, shape in {"hidden_in": [1, 1, 1024], "cos": [1, 1, 64],
                               "sin": [1, 1, 64], "causal_mask": [1, 1, 1, 2048],
                               "current_pos": [1]}.items():
                assert inputs[key]["shape"] == shape, (name, key)
                assert inputs[key]["dtype"] == ("INT32" if key == "current_pos" else "FLOAT16")
            states = contract["states"]
            assert len(states) == 1 and states[0]["name"] == "kv_cache", name
            assert states[0]["shape"] == ([2, 2, 2048, 256] if suffix in "ac" else [4, 2, 2048, 256])
            assert states[0]["dtype"] == "FLOAT16"
            for key, value in inputs.items():
                if key.startswith(("conv_state_", "rec_state_")):
                    output = outputs["new_" + key]
                    assert output["shape"] == value["shape"] and output["dtype"] == value["dtype"]
            if suffix == "d":
                assert outputs["logits"]["shape"] == [1, 1, 248320]
            else:
                assert outputs["hidden"]["shape"] == [1, 1, 1024]
            result[name] = contract
        destination = ROOT / "Evidence/model-contract.json"
        destination.write_text(json.dumps(result, indent=2) + "\n")
        print("PASS: four chunks, one KV MLState per chunk, SSM I/O pairs, full-vocabulary logits")
        print("Core ML compilation / execution / iPhone ANE placement: NOT RUN")


if __name__ == "__main__":
    main()
