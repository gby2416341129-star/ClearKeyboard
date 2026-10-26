#!/usr/bin/env python3
"""Require real macOS Core ML CPU load/predict, independently of Xcode build.

This checks model validity and the complete tiled output numerically. It does
not establish iPhone ANE placement, latency, or input-method accuracy.
"""
import argparse
import gc
import json
from pathlib import Path
import platform
import time
import traceback

import coremltools as ct
import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-directory", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    root = args.model_directory
    info = json.loads((root / "model-info.json").read_text())
    fixtures = np.load(root / "cpu-head-fixtures.npz", allow_pickle=False)
    report = {"platform": platform.platform(), "coremltools": ct.__version__,
              "computeUnits": "CPU_ONLY", "fingerprint": info["fingerprint"],
              "iphoneANEExecutionValidated": False, "stages": [], "passed": False}
    args.report.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.report.write_text(json.dumps(report, indent=2) + "\n")

    def stage(name, function):
        item = {"name": name, "status": "running"}
        report["stages"].append(item)
        save()
        print("NATIVE START", name, flush=True)
        started = time.monotonic()
        try:
            value = function()
            item["status"] = "passed"
            return value
        except Exception as error:
            item.update(status="failed", error=str(error), traceback=traceback.format_exc())
            raise
        finally:
            item["seconds"] = time.monotonic() - started
            save()
            print("NATIVE", item, flush=True)

    def load(name, units=ct.ComputeUnit.CPU_ONLY):
        return stage("load:" + units.name + ":" + name, lambda: ct.models.MLModel(
            str(root / (name + ".mlpackage")), compute_units=units))

    try:
        hidden = fixtures["normed_hidden"]
        reference = fixtures["full_logits"]
        assembled = np.full(reference.shape, np.nan, dtype=np.float32)
        coverage = np.zeros(info["vocabSize"], dtype=np.int32)
        for layout in info["headModels"]:
            model = load(layout["name"])
            for tile in layout["outputs"]:
                coverage[tile["offset"]:tile["offset"] + tile["length"]] += 1
            for sample in range(len(hidden)):
                result = stage(f"predict:{layout['name']}:{sample}", lambda sample=sample:
                               model.predict({info["headInput"]: hidden[sample]}))
                assert set(result) == {tile["name"] for tile in layout["outputs"]}
                for tile in layout["outputs"]:
                    values = np.asarray(result[tile["name"]])
                    assert values.shape == (1, 1, tile["length"])
                    assert np.isfinite(values).all()
                    assembled[sample, tile["offset"]:tile["offset"] + tile["length"]] = values.reshape(-1)
            del model
            gc.collect()
        assert np.all(coverage == 1) and np.isfinite(assembled).all()
        delta = assembled - reference
        relative = float(np.linalg.norm(delta) / np.linalg.norm(reference))
        maximum = float(np.max(np.abs(delta)))
        report["headEquivalence"] = {"samples": len(hidden), "fullVocabulary": info["vocabSize"],
            "maxAbsError": maximum, "relativeL2Error": relative,
            "referenceTop1": reference.argmax(axis=1).tolist(),
            "coreMLTop1": assembled.argmax(axis=1).tolist()}
        # CPU Core ML may choose FP16 accumulation; the unchanged source
        # weights and NumPy FP32 accumulation are not bit-identical arithmetic.
        assert relative < 0.005 and maximum < 0.05, report["headEquivalence"]
        report["headEquivalence"]["passed"] = True
        save()

        token = 248045
        embedding = np.memmap(root / info["embeddingFile"], dtype=np.int8, mode="r",
                              shape=(info["vocabSize"], info["hiddenSize"]))
        scale = np.memmap(root / info["embeddingFile"], dtype="<f2", mode="r",
                          offset=info["vocabSize"] * info["hiddenSize"], shape=(info["vocabSize"],))
        current = (embedding[token].astype(np.float32) * np.float32(scale[token])).astype(np.float16).reshape(1, 1, 1024)
        for suffix in "abcd":
            model = load("chunk_" + suffix)
            inputs = {"hidden_in": current, "cos": np.ones((1, 1, 64), dtype=np.float16),
                "sin": np.zeros((1, 1, 64), dtype=np.float16),
                "causal_mask": np.full((1, 1, 1, 2048), -10000, dtype=np.float16),
                "current_pos": np.array([0], dtype=np.int32)}
            inputs["causal_mask"][..., 0] = 0
            for description in model.get_spec().description.input:
                if description.name.startswith(("conv_state_", "rec_state_")):
                    inputs[description.name] = np.zeros(tuple(description.type.multiArrayType.shape), dtype=np.float16)
            state = model.make_state()
            result = stage("predict:chunk_" + suffix, lambda: model.predict(inputs, state=state))
            for key, value in result.items():
                assert np.isfinite(value).all(), key
            current = np.asarray(result["hidden" if suffix != "d" else info["bodyOutput"]], dtype=np.float16)
            assert current.shape == (1, 1, 1024)
            del model, state, result
            gc.collect()
        report["bodyOneTokenFinite"] = True
        # Record the requested backend too. Hosted Macs need not expose an ANE;
        # this diagnostic never becomes a claim about the user's iPhone.
        diagnostics = []
        for name in ["chunk_d"] + [layout["name"] for layout in info["headModels"]]:
            check = {"name": name, "computeUnits": "CPU_AND_NE"}
            started = time.monotonic()
            print("CNE DIAGNOSTIC", name, flush=True)
            try:
                model = ct.models.MLModel(str(root / (name + ".mlpackage")),
                                          compute_units=ct.ComputeUnit.CPU_AND_NE)
                if name == "chunk_d":
                    result = model.predict(inputs, state=model.make_state())
                else:
                    result = model.predict({info["headInput"]: hidden[0]})
                assert all(np.isfinite(value).all() for value in result.values())
                check["status"] = "passed"
                del model, result
            except Exception as error:
                check.update(status="failed", error=str(error), traceback=traceback.format_exc())
            check["seconds"] = time.monotonic() - started
            diagnostics.append(check)
            report["macCPUAndNeuralEngineDiagnostics"] = diagnostics
            save()
            gc.collect()
        report["passed"] = True
        info.update(nativeCoreMLPredictValidated=True, nativeCoreMLComputeUnits="CPU_ONLY",
                    nativeCoreMLPlatform=platform.platform(), iphoneANEExecutionValidated=False)
        (root / "model-info.json").write_text(json.dumps(info, indent=2) + "\n")
    finally:
        save()


if __name__ == "__main__":
    main()
