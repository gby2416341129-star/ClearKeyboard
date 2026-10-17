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

已在 GitHub macOS / Xcode 26.6 环境完成：31 个 Swift 核心 XCTest 全部通过；主 App 和键盘扩展的 Release arm64 iPhone 目标编译通过；IPA 打包和结构检查通过。构建使用 iPhoneOS 26.5 SDK，最低系统 iOS 18.0。详见 `native-build.json` 和[构建记录](https://github.com/gby2416341129-star/ClearKeyboard/actions/runs/38994072222)。

IPA 检查：云端和下载后的本地检查结果一致；两个可执行文件均为 arm64 iOS 真机平台，内嵌键盘注册正确、两套离线词库及隐私清单齐全。GitHub Artifact、IPA 和随附报告的 SHA-256 相互核对通过。另用已删除的暂存合成 ZIP 验证校验器能拒绝模拟器二进制、缺失扩展、缺少执行权限、缺词库及纯源码 ZIP。交付 IPA **未签名**，不能直接安装到 iPhone。

**尚未验证**：原生 UI 截图、iPhone 安装、签名、真机候选正确率、输入延迟、内存峰值、耗电、微信等宿主的回车发送行为、VoiceOver 与动态字体。

编译、资源和预览检查不能证明原生 App 在 iPhone 的实际运行表现，也不能证明已达到低功耗目标。
