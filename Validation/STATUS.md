# 验证状态 · 2026-10-17

已在本次 Windows 环境完成：

- 21 个 Swift 文件通过 Tree-sitter Swift 语法解析（含 Package.swift 与测试）；这不是 Swift 编译或 Apple SDK 类型检查。
- 65,137 条中文、50,000 条英文记录和 307,696 个索引键全部检查边界、UTF-8、排序、候选 ID 及资源 SHA-256。
- 全拼、简拼、补充短语、英文前缀、拼音分隔和中文续词的代表性数据查找通过。
- Info.plist、App Group entitlements、隐私清单和共享 Scheme 均可解析。
- Xcode 工程通过 OpenStep 解析，98 个对象；全部引用和源码／资源路径存在。
- 原有 11 项浏览器交互与布局检查通过。新增空格长按／光标拖动／取消、触屏、Emoji 字素、任意颜色和 HEX、矢量图标与背景折射检查通过。
- 116 个字形通过独立截图像素居中检查；在本次 1× 浏览器环境中，横向最大误差 < 1 px、纵向最大误差 1 px。
- 预览截图已目视检查；这些结果均仅代表浏览器预览，不代表原生 iPhone 验证。

提供但**未执行**：31 个 Swift 核心 XCTest、Xcode 原生构建、GitHub macOS CI。

IPA 打包准备：提供 `Scripts/build-ipa.sh`、`Scripts/verify_ipa.py` 和手动 macOS 工作流 `.github/workflows/ipa.yml`。已解析工作流配置，并用暂存的合成 ZIP 检查包校验器能拒绝模拟器二进制、缺失扩展、缺少执行权限、缺词库及纯源码 ZIP。合成文件仅用于校验器检查，已删除；**没有生成 IPA，GitHub 连接已确认，等待输入法目标仓库及其访问授权**。Bash 脚本未在 Mac 执行。

**尚未验证**：原生 UI 截图、iPhone 安装、签名、真机候选正确率、输入延迟、内存峰值、耗电、微信等宿主的回车发送行为、VoiceOver 与动态字体。

资源和预览检查不能证明原生 App 已可运行，也不能证明已达到低功耗目标。
