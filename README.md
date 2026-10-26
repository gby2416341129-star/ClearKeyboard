# 澈 · ClearKeyboard

原生 iPhone 中文/英文输入法，包含设置 App 与第三方键盘扩展。中文内核使用本地 Qwen3.5-0.8B Q4_K_M，配合独立 Unicode 拼音约束、候选消费范围及用户学习数据。英文补全使用独立 CMU 词典。

模型仅提供文字推理，不使用视觉模块、云端 API 或备用中文引擎。模型在主 App 包内保存一份，App 和键盘扩展通过同一资源定位接口读取。

在 macOS / Xcode 26+ 执行 `bash Scripts/build-ipa.sh dist`。脚本核对指定 GGUF 的 SHA-256，编译固定版本的 llama.cpp iPhone 运行库及两个 Release arm64 目标，检查发布资源后输出 IPA。设备签名及安装步骤见 [BUILD-IPA.md](BUILD-IPA.md)。

布局、主题、图标、触觉、手势、光标、剪贴板、快捷短语及 App Group 用户数据继续使用现有实现。
