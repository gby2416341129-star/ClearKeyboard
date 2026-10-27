# Qwen 0.8B iPhone ANE 独立后端

本目录只处理 Qwen3.5-0.8B 的 Core ML 后端，未接入或修改 ClearKeyboard 主项目。用户授权的云端实验分支为 `npu/qwen35-08b-calibrated-q4`。

## 4-bit 方案

从 Qwen 原始 BF16 权重直接校准，主体逐输出通道使用独立 LUT4 码表；首尾层及需要提升精度的矩阵采用 LUT6，小型递归门控保留浮点。词嵌入和输出层采用逐行 INT8，词嵌入文件为 254,776,320 bytes。这里的“4-bit”指主体混合精度方案，并非每个参数都占 4 bit。

128 条合成校准样本和 32 条数值验证样本使用当前键盘的 ChatML 提示格式。验证集用于选择混合精度配置，不能作为独立的输入法准确率基准；此过程不属于输入法专项微调。

最终模型目录为 `Models/Qwen3.5-0.8B-IME-Q4`。只有生成 `model-info.json`、四个 `chunk_*.mlpackage` 和对应验证记录后，才代表转换完成。已通过数值门槛和四块模型导出，模型文件实测 817,841,142 bytes（约 818 MB）；独立验证 App 的云端 iPhone arm64 编译通过。大小明细见 `model-info.json`。本地旧目录 `qwen3_5_0_8b_decode_chunks_mlkv` 是 1.262 GB 的 8-bit 比较基线，不进入本次 App。

## 云端构建

`.github/workflows/iphone-ane-probe.yml` 在 Linux 完成校准及可移植模型导出，再由云端 Mac 编译 arm64 iPhone 验证 App。模型、转换记录、未签名 IPA 分别作为 Actions 产物保存。未签名 IPA 需要有效签名后才能安装；云端编译成功不能替代 iPhone 执行。

已通过的云端构建：[GitHub Actions](https://github.com/gby2416341129-star/ClearKeyboard/actions/runs/40387279417)。最新状态以该任务及 `Evidence/preparation-status.json` 为准。

## 接入接口

`QwenANE.logits(for: [Int32])` 返回完整 248,320 词表的原始分数。主项目提供现有候选解码逻辑；本地交付包的 `Tokenizer/` 提供同一原始版本的 tokenizer（约 12.8 MB）。GitHub 源码构建可从固定的 Qwen 原始版本取得这些文件。连续追加复用 KV/SSM；改写、退格、上下文变化会重置重放。取消在 token/chunk 边界生效。

采用公开 iOS 18+ Core ML API，配置为 `.cpuAndNeuralEngine`。它允许 CPU 与 ANE，不能据此宣称所有运算都在 NPU。没有重复惩罚或采样修补来掩盖输出偏差。

Build 8 的运行库默认采用 `.cpuAndNeuralEngine`。显式请求 `.all` 且加载返回 Core ML 执行计划错误 `-14` 时，默认加载策略释放失败尝试中的整套实例，再完整创建 CPU+ANE 实例；不会混用两套状态，不重试取消或其他类型错误，不切换到 GPU。需要严格比较时传入 `loadPolicy: .strict`。`loadReport` 保留请求配置、实际配置、各次加载耗时、失败模型和完整原始错误。

自动验证 App 的 `.all` 项启用上述恢复，成功恢复后状态为 `recovered`，不计为 `.all` 成功；CPU+GPU 和 CPU+ANE 两项使用严格策略。导出的 schema 6 单独记录 `effectiveComputeUnits`、`loadAttempts` 和 `planComputeUnits`，恢复后的耗时与算子计划均属于实际配置。Build 7 已由用户验证的前缀检查点保留；Build 8 只编译打包，所有执行测试由用户完成。

## 独立 iPhone 验证 App

App 首次在手机上编译模型，读取该设备的 `MLComputePlan`，执行固定提示并允许导出设备、耗时、采样内存及算子计划记录。计划表示预期分配，实际 ANE 硬件执行仍需真机证据；`hardwareTraceCaptured` 和 `keyboardExtensionTested` 保持 false。

短前缀的 PyTorch 分块结构已与原模型对照；记录在 `Evidence/chunk-parity.json`。这不替代压缩模型检查或真机测试。打字准确率、长输入速度及键盘扩展体验由用户验证。

## 固定来源

- [Qwen3.5-0.8B 原始权重](https://huggingface.co/Qwen/Qwen3.5-0.8B/tree/2fc06364715b967f1860aea9cf38778875588b17)，Apache 2.0，见 `LICENSE-QWEN.txt`。
- [CoreML-LLM MLKV 图结构](https://github.com/john-rocky/CoreML-LLM/tree/e45a7a61dd7e35ba58dd14aa7a8f843c8caa3f0f)，MIT，见 `THIRD_PARTY_NOTICES.txt`。
- [Apple MLState](https://developer.apple.com/documentation/coreml/mlstate)、[MLComputePlan](https://developer.apple.com/documentation/coreml/mlcomputeplan-1w21n)。
