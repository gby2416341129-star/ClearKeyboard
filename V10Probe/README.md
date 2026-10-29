# 澈 V10 独立 iPhone 测试 App

独立项目，`local.che.v10probe`，iOS 18+。仅打包 V10 排序/采用模型与交付包中的固定参考样例，不修改澈输入法，不包含 Qwen、Rime、万象或旧 ANE 模型。

安装 IPA 后点 **开始完整测试**，保持 App 在前台，结束后点 **导出记录**。四种配置自动顺序运行：CPU、CPU+GPU、CPU+ANE、全部可用计算单元；顺序随机并记录。失败保存原生错误后继续下一配置，停止或被系统中断的记录也可导出。

每种配置记录首次加载/首次推理、20 次预热、600 次纯模型推理、180 次适配调用（保护输入单独统计）、8 次间歇调用、同进程再次加载，以及随后读取的 MLComputePlan。纯模型使用冻结输入；适配调用包括文本编码和模型决策，不包括候选生成与键盘 UI。所有计时和原始样本都来自用户在手机点击开始后的实际调用。

模型推理无应用结果缓存。系统/Core ML 的编译和设备特化缓存无法通过本工具可靠清空，因此“首次加载”不宣称为真正无缓存冷启动。每种配置严格执行，不静默回退。Core ML 允许配置与编译器计划不证明 ANE 硬件执行，`hardwareTraceCaptured=false`；不验证键盘扩展。电池、温度状态和进程 CPU 时间只是环境信息，功耗瓦数未测量。内存为 20ms 间隔采样的进程物理 footprint。

15 个参考样例用于接口/数值行为对照，不能作为真实输入准确率。源模型版本仍为 V10，research_only=true，deployment_ready=false。校准已在图内，外部仅使用交付阈值 0.65 和保护输入规则。

构建：在 macOS/Xcode 执行 `bash Scripts/build_probe.sh`。构建过程不运行模型、模拟器、测试或基准。IPA 未签名，沿用用户自己的签名安装方式。

原始交付：`Delivery/V10_iPhone_Trial_Bundle`。项目源资源由 `Scripts/prepare_assets.py` 从该包复制；保持模型权重与参考文件原值。不要把整个训练交付目录加入 App target。构建云端分支仅包含本项目所需的 Model、Assets、Sources、Scripts。
