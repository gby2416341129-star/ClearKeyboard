# 生成 iPhone IPA

**已生成 0.1.1（2）未签名 IPA。** [成功的云构建](https://github.com/gby2416341129-star/ClearKeyboard/actions/runs/38994072222) 使用 Xcode 26.6，通过 31 项核心测试、主 App 和键盘扩展的 Release arm64 iPhone 目标编译、IPA 包检查。可从该次运行的 Artifacts 下载；安装前仍需签名。

## GitHub 云构建

1. 将本目录内容放到你自己的 GitHub 仓库根目录。根目录应直接包含 `ClearKeyboard.xcodeproj`、`Package.swift` 和 `.github`，不要再嵌套一层 `ClearKeyboard/`。
2. 推送到 `main` 分支会自动构建；也可打开仓库 **Actions → Build unsigned iPhone IPA → Run workflow** 手动构建。
3. 工作流在 `macos-26` 的 Xcode 环境执行词库检查、Swift 核心测试、Release 真机编译。
4. 成功后，从该次运行的 **Artifacts → ClearKeyboard-unsigned-IPA** 下载 ZIP 并解压，取得 `ClearKeyboard-unsigned.ipa`、SHA-256 和检查报告。
5. 构建失败时只会得到错误日志，不会把源码或模拟器程序当成 IPA。

该工作流在 `main` 分支推送或手动触发时运行，不含签名密码、证书、Apple ID，也不上传 App Store。使用标准 GitHub macOS runner；私有仓库会使用你账号的 Actions 分钟额度。

## Mac 本地构建

要求 macOS 和完整 **Xcode 26+**，仅 Command Line Tools 不够。

```bash
swift test
bash Scripts/build-ipa.sh
```

输出在 `dist/ClearKeyboard-unsigned.ipa`。脚本只在 Xcode 真机编译成功后打包 `Payload/ClearKeyboard.app`，包括 `PlugIns/ClearKeyboardExtension.appex`，并检查两个 arm64 iOS 可执行文件和离线词库。

## 安装与签名

**未签名 IPA 不能直接在 iPhone 安装。** 签名须覆盖主 App 和内嵌的键盘扩展，使用匹配的 Bundle ID、描述文件与 App Group 权限。修改 Bundle ID 时需同时更新 App Group。

使用 Apple Developer 的开发或设备测试分发时，在 Xcode 配置 `Config/Project.xcconfig` 的基础 Bundle ID 和 Team，为两个目标配置相同 App Group，然后 Archive 并导出匹配设备的 IPA。证书和配置文件应在你自己的钥匙串或云构建 Secrets 中管理。

安装后在「设置 → 通用 → 键盘」添加“澈”。原生 Liquid Glass 需要 iOS 26+；最低系统为 iOS 18。云构建通过不代表已完成真机流畅度、能耗或宿主兼容测试。

参考：[GitHub macOS runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[Apple 设备分发与 IPA 导出](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)。
