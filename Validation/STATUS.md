# 验证状态 · 0.1.2（3）· 2026-10-17

## GitHub / Xcode

主 App 和键盘扩展均通过 Xcode 26.6（17F113）的 Release arm64 iPhone 目标编译；使用 iPhoneOS 26.5 SDK，最低系统 iOS 18.0。33 个 Swift 核心 XCTest 全部通过。[构建记录](https://github.com/gby2416341129-star/ClearKeyboard/actions/runs/38997390063)，源码提交 `7f5c6b54ad66b0f9794853e07bd822886de13326`。

在 iPhone 17 Pro / iOS 26.5 模拟器中，8 项原生 XCTest 全部通过：

- 初次布局为零或极小尺寸时，按键视图没有无限或空矩形坐标。
- 键盘控制器在尚未连接宿主时可加载、布局、接收生命周期回调，公开 Objective-C 主类名可解析。
- App 内按键输入 `nihao` 能显示有实际宽高的「你好」候选；空格上屏；英文 `hell` 能补全并输入 `hello `。
- 重复的选区通知不会清空拼音，普通 SwiftUI 更新不会重置当前中英文语言。
- UITextView 编辑回调进入同一套中文输入引擎。
- 左右单手模式均可更改工具栏顺序，保留换手、尺寸调整和全尺寸侧栏。
- 固定高度体验区出现候选时，底排按键完整可见。
- 首页浅色与深色截图、安全区检查通过。

截图保存在 `NativeScreenshots/`，测试摘要见 `native-runtime.json`。截图来自原生 UIKit / SwiftUI 窗口；不包含由系统进程绘制的状态栏。

## Windows 本地

25 个 Swift 文件通过语法解析；完整词库、属性清单、权限文件和 Xcode 工程引用检查通过。工程有 135 个对象。预览的 12 项交互检查通过，包括工具栏增删与拖动排序、左右手切换、候选输入、颜色和 400 px 响应式布局。

IPA 在云端及下载后分别完成 ZIP 完整性、元数据、扩展注册、执行权限、arm64 iOS 真机平台、两套词库和隐私清单检查，结果一致。Artifact、IPA、校验文件和检查报告的 SHA-256 核对一致。扩展元数据的主类名与二进制中的公开 Objective-C 类名一致。

## 崩溃修正与验证范围

原生测试重现了 `KeyboardViewController.viewDidLoad()` 读取空文档 ID 时发生的 `UUID._unconditionallyBridgeFromObjectiveC` / SIGTRAP。现在通过同一个公开属性的 Objective-C getter 保留空值，回归检查通过。同时修正了零尺寸按键底板的无效几何。

初始化测试刻意覆盖尚未建立远程连接的状态；不模拟已安装键盘与第三方 App 的跨进程连接。App 内候选与编辑另由真实 UIKit 控件测试。

交付 IPA 未签名。尚未完成本次新包在 iPhone 上的重新签名、安装和实际切换验证，也未测量真机延迟、耗电或内存峰值。微信等宿主的回车发送行为、VoiceOver 和动态字体仍待真机检查。
