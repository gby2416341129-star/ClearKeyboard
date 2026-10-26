"""Exact-value aggregation for coremltools 9.0 weighted scalar SKM.

Call install() before SKMPalettizer.compress(). The importable subclasses keep
the override active inside coremltools' spawn workers. No weight rounding or
Fisher approximation is added. Float64 summation can change numerical tie
breaking, so equivalence concerns the weighted objective, not identical bytes.
"""
from __future__ import annotations

import argparse
import copy
import io
import json
import os
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import tempfile

import numpy as np
import torch

from coremltools._deps import _kmeans1d
from coremltools.optimize.torch._utils.k_means import (
    KMeansConfig,
    ParallelKMeans as _NativeParallelKMeans,
    SequentialKMeans as _NativeSequentialKMeans,
)
from coremltools.optimize.torch.palettization import (
    SKMPalettizer,
    SKMPalettizerConfig,
)
from coremltools.optimize.torch.palettization import sensitive_k_means as _skm

_PROBE_ENV = "QWEN_SKM_UNIQUE_SELF_TEST_DIR"


def _record_self_test_worker(cls):
    """Optional, bounded evidence that a spawned worker used this override."""
    directory = os.environ.get(_PROBE_ENV)
    if directory:
        marker = Path(directory) / f"worker-{os.getpid()}.json"
        if not marker.exists():
            marker.write_text(json.dumps({
                "pid": os.getpid(), "module": cls.__module__, "class": cls.__name__,
            }), encoding="utf-8")


class _UniqueWeightedScalarMixin:
    @classmethod
    def _cluster_weights_1d(cls, block_weight, block_importance, config):
        if block_importance is None:
            return super()._cluster_weights_1d(block_weight, block_importance, config)
        if _kmeans1d is None:
            raise RuntimeError("coremltools' native weighted kmeans1d is unavailable")
        if block_weight.device.type != "cpu" or block_importance.device.type != "cpu":
            raise ValueError("Scalar SKM clustering expects CPU tensors")

        # BF16 -> FP32 is exact. Do not round weights or cast FP32 to FP16.
        weight = block_weight.detach()
        if weight.dtype == torch.bfloat16:
            weight = weight.float()
        values = weight.reshape(-1).numpy()
        importance = block_importance.detach().to(torch.float64).reshape(-1).numpy()
        if values.size == 0 or values.size != importance.size:
            raise ValueError("Empty or misaligned weight/importance arrays")
        if not np.isfinite(values).all():
            raise ValueError("Non-finite scalar SKM weights")
        # SKM's processed Fisher values are strictly positive (clipped at 1e-12).
        if not np.isfinite(importance).all() or np.any(importance <= 0):
            raise ValueError("Processed SKM importance must be finite and positive")

        unique_values, inverse = np.unique(values, return_inverse=True)
        inverse = inverse.reshape(-1)
        summed_importance = np.bincount(
            inverse, weights=importance, minlength=unique_values.size,
        )
        if not np.isfinite(summed_importance).all():
            raise ValueError("Overflow while summing Fisher importance")
        clustered = _kmeans1d.cluster(
            unique_values,
            min(2 ** config.n_bits, unique_values.size),
            weights=summed_importance,
        )
        centroids = np.asarray(clustered.centroids, dtype=np.float64)
        labels = np.asarray(clustered.clusters, dtype=np.int64)[inverse]
        if not np.isfinite(centroids).all():
            raise ValueError("Native weighted kmeans1d returned non-finite centroids")
        _record_self_test_worker(cls)
        # The original coremltools method also returns float64 centroids and
        # int64 labels. Its worker handles casting and padding the final LUT.
        return torch.from_numpy(centroids), torch.from_numpy(labels)


class UniqueParallelKMeans(_UniqueWeightedScalarMixin, _NativeParallelKMeans):
    pass


class UniqueSequentialKMeans(_UniqueWeightedScalarMixin, _NativeSequentialKMeans):
    pass


def install():
    """Replace only SKM's dispatcher classes; unweighted work delegates unchanged."""
    if _kmeans1d is None:
        raise RuntimeError("Install a coremltools 9.0 wheel containing native kmeans1d")
    _skm._ParallelKMeans = UniqueParallelKMeans
    _skm._SequentialKMeans = UniqueSequentialKMeans


def _objective(weight, importance, reconstructed):
    x = weight.detach().to(torch.float64).reshape(-1).numpy()
    w = importance.detach().to(torch.float64).reshape(-1).numpy()
    y = reconstructed.detach().to(torch.float64).reshape(-1).numpy()
    return float(np.dot(w, np.square(x - y)))


def _check_objective(weight, importance, before, after, *, rtol=1e-9):
    a = _objective(weight, importance, before)
    b = _objective(weight, importance, after)
    energy = float((weight.double().square() * importance.double()).sum())
    np.testing.assert_allclose(a, b, rtol=rtol, atol=2e-12 * max(1.0, energy))


def self_test():
    """Run only with Apple's native weighted library; no surrogate success path."""
    if _kmeans1d is None:
        raise RuntimeError("Self-test requires coremltools' native weighted kmeans1d")
    torch.set_num_threads(1)
    generator = torch.Generator().manual_seed(20261027)
    palette = torch.linspace(-1.25, 1.25, 43).bfloat16().float()
    weight = palette[torch.randint(len(palette), (512,), generator=generator)]
    importance = torch.exp(torch.randn(512, generator=generator) * 2).clamp_min(1e-8)
    config = KMeansConfig(n_bits=4, axis=0, block_size=1, cluster_dim=1)
    native_centroids, native_labels = _NativeSequentialKMeans._cluster_weights_1d(
        weight, importance, config,
    )
    unique_centroids, unique_labels = UniqueSequentialKMeans._cluster_weights_1d(
        weight, importance, config,
    )
    _check_objective(weight, importance,
                     native_centroids[native_labels], unique_centroids[unique_labels])
    if unique_labels.shape != native_labels.shape or unique_labels.dtype != torch.int64:
        raise AssertionError("Scalar clustering label contract changed")

    # Four small Linear tensors provide work for two actual spawn workers.
    toy = torch.nn.Sequential(*[torch.nn.Linear(128, 8, bias=False) for _ in range(4)])
    fisher = {}
    native_config = {}
    with torch.no_grad():
        for name, module in toy.named_modules():
            if not isinstance(module, torch.nn.Linear):
                continue
            module.weight.copy_(palette[torch.randint(
                len(palette), module.weight.shape, generator=generator,
            )])
            sensitivity = torch.exp(torch.randn(
                module.weight.shape, generator=generator,
            ) * 2).clamp_min(1e-8)
            fisher[name + ".weight"] = sensitivity
            native_config[name] = {"weight": KMeansConfig(
                n_bits=4, axis=0, block_size=1, cluster_dim=1,
                importance=sensitivity,
            )}
    original = copy.deepcopy(toy)
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        native = _NativeSequentialKMeans.cluster_weights(copy.deepcopy(toy), native_config)

    old_parallel, old_sequential = _skm._ParallelKMeans, _skm._SequentialKMeans
    old_probe = os.environ.pop(_PROBE_ENV, None)
    try:
        install()
        if _skm._ParallelKMeans is not UniqueParallelKMeans:
            raise AssertionError("SKM parallel dispatcher was not replaced")
        if _skm._SequentialKMeans is not UniqueSequentialKMeans:
            raise AssertionError("SKM sequential dispatcher was not replaced")
        with tempfile.TemporaryDirectory(prefix="skm-unique-test-") as directory:
            directory = Path(directory)
            fisher_path = directory / "fisher.pt"
            torch.save(fisher, fisher_path)
            os.environ[_PROBE_ENV] = str(directory)
            skm_config = SKMPalettizerConfig.from_dict({"global_config": {
                "n_bits": 4, "granularity": "per_grouped_channel",
                "group_size": 1, "channel_axis": 0, "cluster_dim": 1,
                "enable_per_channel_scale": False, "lut_dtype": None,
            }})
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                optimized = SKMPalettizer(toy, skm_config).compress(
                    sensitivity_path=str(fisher_path), num_kmeans_workers=2, inplace=True,
                )
            evidence = [json.loads(p.read_text()) for p in directory.glob("worker-*.json")]
            if not any(record["pid"] != os.getpid()
                       and record["module"] == "skm_unique"
                       and record["class"] == "UniqueParallelKMeans" for record in evidence):
                raise AssertionError("No spawn worker executed the importable unique subclass")

            for name, reference in native.named_modules():
                if not isinstance(reference, torch.nn.Linear):
                    continue
                candidate = optimized.get_submodule(name)
                raw = original.get_submodule(name).weight
                _check_objective(raw, fisher[name + ".weight"],
                                 reference.weight, candidate.weight, rtol=1e-7)
                before = dict(reference.named_buffers(recurse=False))
                after = dict(candidate.named_buffers(recurse=False))
                lut_key = "_COREML_/weight/lut"
                type_key = "_COREML_/weight/compression_type"
                if after[lut_key].shape != before[lut_key].shape:
                    raise AssertionError("LUT metadata shape changed")
                if after[lut_key].shape[-2] != 16 or not torch.isfinite(after[lut_key]).all():
                    raise AssertionError("Invalid LUT4 metadata")
                if after[type_key].tolist() != [2]:
                    raise AssertionError("Palettization metadata type changed")
    finally:
        _skm._ParallelKMeans, _skm._SequentialKMeans = old_parallel, old_sequential
        if old_probe is None:
            os.environ.pop(_PROBE_ENV, None)
        else:
            os.environ[_PROBE_ENV] = old_probe
    print("PASS native weighted objective; spawn=2 unique override; LUT4 metadata")


def _main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if not args.self_test:
        parser.error("Use --self-test, or import install() from this module")
    self_test()
    return 0


if __name__ == "__main__":
    # Give spawned workers a stable module path even when invoked as a script.
    import skm_unique
    raise SystemExit(skm_unique._main())
