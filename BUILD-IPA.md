# iPhone IPA

在 macOS / Xcode 26+ 与 Python 3.12 环境执行 `bash Scripts/build-ipa.sh dist`。脚本校验正式 V22 SDK 资源并编译提供的 V22 紧凑导出模型（V19 权重）、App 与键盘扩展，输出未签名 IPA 及 SHA-256，不运行测试。

V22 编译模型只在键盘扩展内打包一份。签名时同时处理主 App 与键盘扩展，保持现有 Bundle ID 与 App Groups。用户数据沿用原存储。
