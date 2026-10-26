# iPhone IPA

在 macOS、Xcode 26+、Python 3.12 和 CMake 环境执行：

```sh
bash Scripts/build-ipa.sh dist
```

脚本仅下载并校验 `Qwen3.5-0.8B-Q4_K_M.gguf`、独立 Unicode 拼音数据和固定提交的 llama.cpp 源码。随后编译本地 iPhone 推理运行库、App 和键盘扩展，输出 `dist/ClearKeyboard-unsigned.ipa` 及 SHA-256。构建流程不运行打字或性能测试。

模型只在 `ClearKeyboard.app/Models` 中打包一份，键盘扩展从包含它的 App 包读取，不复制到用户数据容器。

现有无证书流程输出未签名 IPA。安装时需要按既有流程同时签名主 App 和 `PlugIns/ClearKeyboardExtension.appex`，并保留相同 App Group 权限。使用 Apple Developer 分发时，配置 `Config/Project.xcconfig` 的 Bundle ID 和 Team，再通过 Xcode Archive 导出。不要提交签名私钥。

安装后在 iPhone「设置 → 通用 → 键盘」添加“澈”。用户设置、个人词库、快捷短语和学习记录继续保存在原有 App Group 中。
