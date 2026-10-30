# V19 iPhone standalone latency probe

Independent native iPhone application for the user to measure V19 step38750.
Uses the delivered FP16 Core ML model and the delivered Swift/C++ full-pinyin
kernel. The model, dictionaries, segmentation and decoding algorithms are unchanged.
The copied SDK has diagnostic loading and per-model-call timers only.

One start button runs CPU, CPU+GPU, CPU+ANE, and all allowed compute units in
random order. JSON export includes first model loading, resource/kernel preparation,
first model call, first full request, warmed single-model latency (300 samples),
complete native kernel latency (120 requests, all original segmentation paths),
idle full requests, explicit release/reload, sampled process memory and errors.

P50/P95/P99 use nearest rank and retain individual samples. No prediction cache,
system-cache deletion, pre-inference before first request, or configuration fallback.
No compute-plan scan is performed. Hardware trace and power in watts are not measured.
Reference comparisons are interface/export diagnostics, not an accuracy acceptance test.

The generic iOS Release build compiles the model to mlmodelc and C++ code to
native ARM64. It does not execute predictions, benchmarks or tests. Phone-side
measurements belong to the user. The app is separate from ClearKeyboard.

ModelParts contains exact byte chunks for upload only. restore_model.py verifies
and reconstructs them before compilation; chunks are never bundled into the IPA.
