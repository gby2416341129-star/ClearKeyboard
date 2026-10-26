# 独立 iPhone Qwen ANE 验证工程

当前工作已切换到**原始 Qwen BF16 → 中文输入 Fisher 校准 → 以 LUT4 为主的混合精度 Core ML**。入口为 `Conversion/build_q4.py`。首尾层保留 LUT6、小型递归门控保留浮点、输出层为 INT8，词嵌入表采用逐行 INT8 + FP16 scale。128 条合成校准输入与 32 条独立留出输入使用当前键盘的提示格式；它们用于检查量化偏差，不代表实际打字准确率。

用户已授权在 `npu/qwen35-08b-calibrated-q4` 实验分支运行云端构建；主分支与 ClearKeyboard 本地工程保持独立。量化和可移植模型导出在 Linux runner 完成，再由云端 Mac 编译 iPhone 验证 App。旧 1.26 GB 文件只保留在本地作为比较基线，不进入该 4-bit App 的资源列表。下文记录原始验证基线，4-bit 的实际大小与验证结果以新产物 JSON 为准。

只负责 Qwen3.5-0.8B 的 Core ML / ANE 后端。本目录独立于 ClearKeyboard，尚未接入键盘，也未修改主项目。

当前准备：锁定并下载 4 块 MLKV 模型及 embedding；全部文件按上游摘要校验；解析 protobuf 核对输入、输出、状态和 2048-token 容量。原型使用公开 iOS 18+ Core ML API，CPU+ANE 配置排除 GPU。**本机是 Windows，Swift 尚未通过 Apple SDK 编译，iPhone ANE 执行也未验证。**

## 不需要自有 Mac

独立仓库中的 `.github/workflows/iphone-ane-probe.yml` 使用 GitHub 的 macOS runner，构建 arm64 验证 App 并输出未签名 IPA 和日志。当前仅准备了流程，**尚未上传仓库或启动云端任务**。未签名 IPA 仍需要有效签名才能安装到 iPhone。

本地 Mac 的等效命令是 `bash Scripts/build_probe.sh`。Xcode 工程已经生成，可设置开发团队后直接运行。GitHub 虚拟机和模拟器的结果均不能替代 iPhone ANE 证据。

## 模型大小

模型文件共 **1,261,991,992 bytes = 1.262 GB = 1.175 GiB**，其中 embedding 508,559,360 bytes，其余主要是四块模型的权重。正式替换旧约 0.53 GB GGUF 后，模型部分净增加约 0.73 GB。App 自身、编译缓存、更新过程占用另计。推理内存不等于模型文件总大小。

此版本是独立可行性验证基线，体积不能视作最终上架方案。进一步缩小量化位数或 embedding 会改变数值，需要另行验证。

## 实机验证范围

验证 App 读取设备上的 `MLComputePlan`，执行固定的 18-token 提示和最多 16 个输出 token，并导出设备型号、OS、模型版本、耗时、采样到的内存占用、完整算子分配计划。没有自有 Mac 时，可先导出手机内的计划与成功预测记录。算子计划表示预期分配；如需进一步确认实际硬件执行，可用连接真机的 Mac 在 Instruments 联合查看 Core ML、Neural Engine、GPU 和 signpost 轨迹。云端 Mac 不能直接采集未连接的本地 iPhone USB 轨迹。

导出的 `hardwareTraceCaptured`、`keyboardExtensionTested` 固定为 false，避免把一次 App 推理误报成硬件轨迹或键盘验收。候选准确性、输入手感、长输入速度由用户后续验收；键盘扩展的内存和生命周期仍需独立实机验证。

## 给主项目的接口

`QwenANE.logits(for: [Int32])` 返回完整词表原始分数；匹配的 tokenizer 和拼音约束候选解码由主项目负责。相同前缀的追加请求复用 KV/SSM 状态；改写、退格或上下文变化会重置重放。取消发生在 token/chunk 边界，不能中断已经提交的单次 Core ML 同步预测。

不自动加重复惩罚。上游 v1.8 报告约 45–50 token/s，但其文档说明使用重复惩罚缓解部分 iPhone 输出偏差，且最初几个 token 仍可能不一致。因此该数字不能作为输入法首候选准确率、iPhone Air 速度或能效结论。正式接入前必须核对短输出和数值偏差，不能通过采样策略掩盖。

## 来源

- [CoreML-LLM 锁定源码](https://github.com/john-rocky/CoreML-LLM/tree/e45a7a61dd7e35ba58dd14aa7a8f843c8caa3f0f)
- [锁定模型版本](https://huggingface.co/mlboydaisuke/qwen3.5-0.8B-CoreML/tree/82700f499b705c64c594c42deff684ec0321bcce)
- [上游短输出偏差说明](https://github.com/john-rocky/CoreML-LLM/blob/e45a7a61dd7e35ba58dd14aa7a8f843c8caa3f0f/docs/QWEN35_FULL_VOCAB_REP_PENALTY.md)
- [Apple MLState 并发约束](https://developer.apple.com/documentation/coreml/mlstate)
- [Apple Core ML 硬件分析](https://developer.apple.com/videos/play/wwdc2022/10027/)
- [GitHub macOS runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
