# 澈 · ClearKeyboard

面向中文和英文的原生 iPhone 输入法，当前版本 **0.1.2 开发预览**。包含 SwiftUI 设置 App、UIKit 系统键盘扩展、离线词库和交互设计预览。

**已生成未签名 IPA。** [GitHub 云构建](https://github.com/gby2416341129-star/ClearKeyboard/actions/runs/38997390063) 使用 Xcode 26.6 / iPhoneOS 26.5，主 App 和键盘扩展均通过 Release arm64 真机目标编译，33 个 Swift 核心测试全部通过。8 项原生运行测试全部通过，并已检查浅色、深色、单手和候选截图。安装前仍需签名；具体记录见 `Validation/native-build.json`，iPhone 真机切换、性能与耗电仍待验证。

IPA 打包入口已提供：参见 [BUILD-IPA.md](BUILD-IPA.md)。可推送至 GitHub 的 `main` 分支自动构建、手动运行工作流，或在 Mac 执行 `bash Scripts/build-ipa.sh`；只有真机编译通过后才会生成包含键盘扩展的未签名 IPA，安装前仍需签名。

## 布局与设计

字母采用 iOS 系统式 QWERTY：第一排 10 键、第二排 9 键并左右缩进、第三排 Shift / Z–M / 删除。数字和符号保持系统式页序、位置关系，底排为 123 / 地球 / 空格 / 回车。

按键的字符顺序不开放重排，以遵循最新确认的系统布局要求。可自定义按键高度、任意 RGB 颜色、玻璃遮罩浓度、工具栏顺序与显隐、左右单手宽度。四个角采用连续曲线裁切；iOS 26 通过公开的容器同心圆角 API 适配，较早系统使用连续圆角回退。

- `Design/preview.html`：可直接在浏览器打开；不需要安装依赖或联网。
- `Design/preview-desktop.png` / `preview-phone.png`：已检查的设计预览。
- 设计预览使用少量示例候选。原生 App 的体验区和系统扩展共用完整 Swift 输入引擎与键盘视图。
- 原生 App 自动适应深浅色；HTML 预览展示浅色设计。

## 本次界面与交互修正

0.1.2 移除了键盘闲置时的状态说明行，改为左侧品牌入口、右侧三个快捷工具；点品牌打开工具网格，长按快捷工具可增删和拖动排序。工具栏与按键一起靠左或靠右，另一侧提供换手、尺寸调整和恢复全尺寸。主 App 使用新的 C 形标志、紧凑标题和安全区布局。

体验区的普通 SwiftUI 刷新会保留键盘当前语言；选区的重复通知不会清空拼音。候选栏按内容测量宽度，外部文本编辑事件也进入相同输入引擎。首次键盘布局为零尺寸时，按键底板会保持有限、非负的尺寸。键盘尚未连接宿主时，空的文档 ID 不再触发 Swift UUID 转换崩溃。

按键字符改为按可见字形轮廓居中；预览通过 116 个字形的截图像素检查，四种状态覆盖小写、大写、数字和符号。工具栏、地球、Shift、删除和底部导航均采用统一线条图标，原生使用 SF Symbols。

预览的玻璃使用 SVG 位移图对背景采样折射，并保留边缘反射和按压高光；这不是 iOS 原生材质的截图。原生代码采用独立玻璃按键和共享玻璃容器，已通过 Xcode 编译，仍待真机视觉与交互检查。

按住空格约 350 ms 后进入光标移动模式，隐藏按键字符并显示手势提示；横向移动按字素推进光标，松手或中断不追加空格。预览已验证鼠标、触屏、越出空格范围、文本边界和组合 Emoji。

颜色不再限于预设：主 App 提供系统取色器和 HEX；键盘内提供 RGB 滑杆；预览支持任意颜色取色器和 HEX，包括黑白。

## 已实现的源码能力

| 能力 | 当前实现 |
| --- | --- |
| 原生扩展 | `UIInputViewController`，标准地球键与系统键盘选择菜单 |
| 玻璃 | iOS 26 原生 `UIGlassEffect`；iOS 18–25 系统材质；清透 / 柔雾 / 纯净、浓度；系统取色器、HEX 和键盘 RGB 滑杆，预设色作为快捷入口 |
| 中文输入 | 65,137 个词条，全拼、前缀补全、简拼、显式拼音分隔、基础词句组合、局部选词后继续输入 |
| 英文输入 | 50,000 个词条，前缀补全、有限常用续词、大小写继承、句首大写 |
| 模糊音 | z/zh、c/ch、s/sh、n/l、f/h、an/ang、en/eng、in/ing；按组开关、最多 12 个变体 |
| 预测 | 中文词条前缀续词；英文有限常用搭配；可关闭续词 |
| 选词学习 | 默认关闭；本地已选词计数，最多 512 条；延后写入；清除后旧进程不会回写被清除数据 |
| 单手 | 左 / 右 / 标准；工具栏随键盘靠边；侧栏换手、调整尺寸、一键恢复；宽度 68%–88% |
| 编辑 | 双击 Shift 锁定大写、长按删除连续删除、长按空格进入光标移动模式；左右滑动、松手不插入空格 |
| 工具栏 | 最多三个快捷工具；在键盘内增删、拖动排序；所有模式共用设置，中英切换始终在品牌工具面板可用 |
| 剪贴板 | 用户主动读取；最多 20 条、每条 2,000 字、最多固定 10 条；未固定内容到期清理 |
| 表情 | Unicode Emoji、颜文字、内置文字贴纸；图片贴纸点按复制后在消息框粘贴 |
| 回车 | 跟随宿主的回车类型显示标签；有拼音先确认，再输入回车字符 |
| 隐私 | 无账号、广告、网络请求、遥测；不保存原始按键或整段输入；附隐私清单及词库许可 |

英文优先级由本项目的常用词排序和长度启发式生成，**不是语料统计词频**。当前预测属于词典与规则方案，尚未集成神经语言模型。中文模糊音为有界变体匹配，词句组合为基础动态规划；长句质量、纠错与上下文理解需要继续加强。

## 在 Mac 上运行

要求：**macOS、Xcode 26 或更新版本、iOS 18+**。原生 Liquid Glass 需要 iOS 26+。工程和共享 Scheme 已生成，不依赖 CocoaPods、XcodeGen 或外部 Swift 包。

1. 打开 `ClearKeyboard.xcodeproj`，选择 `ClearKeyboard` Scheme。
2. 在模拟器直接构建运行。首次运行先使用 App 内体验区。
3. 真机安装前，修改 `Config/Project.xcconfig` 中的 `CLEAR_BASE_BUNDLE_IDENTIFIER` 和 `DEVELOPMENT_TEAM`。
4. 为 App 和 Extension 配置同一个 App Group（`group.<你的基础 Bundle ID>`），并确认开发团队具备相应签名能力。
5. 安装 App 后，打开 iPhone 的「设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 澈」。输入时长按地球键切换。
6. 如需主 App 设置同步、剪贴板和图片贴纸，按需开启「完全访问」。未开启时仍可离线输入，键盘内外观与单手设置保存在扩展本地。

执行检查：

```bash
bash Scripts/verify-macos.sh
```

这会运行数据验证、Swift 核心 XCTest、模拟器目标构建。`bash Scripts/test-native.sh` 另在 iPhone 模拟器中运行 UIKit 交互与截图测试。`.github/workflows/ipa.yml` 同时包含核心测试、iPhone 目标编译、IPA 打包和原生界面测试。

## 流畅与能耗的实现选择

- 按键反馈直接处理，词库加载与完整候选查询在串行后台队列执行，无人为防抖等待。
- 每次请求带代号并取消旧任务；旧候选在刷新时暂时禁用，旧结果不能覆盖新拼音。
- 空格快速上屏使用当前代号匹配的候选，必要时执行有界索引查询，避免选中上一个拼音的词。
- 词库为约 13.7 MiB 的只读二进制索引，使用 `Data.mappedIfSafe`，不展开整棵字典树。
- iOS 26 按键使用独立原生玻璃表面，通过一个 UIGlassContainerEffect 容器统一合成；工具栏使用独立圆形按钮。输入时不重建全部按键或材质。此方案的实际 GPU 开销仍需真机测量。
- 不使用常驻刷新循环、后台剪贴板轮询或逐帧玻璃动画。删除计时器仅在长按期间运行并在隐藏时停止。
- 低电量、减少透明度、纯净材质时关闭背景玻璃。无动画也自然适应减少动态效果的需求。
- 本地选词写入合并并延迟执行。日志仅记录动作耗时区间，不写入用户文本。

上述是实现策略，**不是已经测得的省电或延迟结论**。

## 真机验收门槛（待测）

| 项目 | 验收目标 |
| --- | --- |
| 输入动作主线程耗时 | 暖机 p95 < 8 ms，使用 Points of Interest 的 `KeyAction` 区间测量 |
| 候选端到端延迟 | 常用短语暖机 p95 < 24 ms；需补充端到端采样 |
| 打字与滚动 | 60 / 120 Hz 设备检查 Animation Hitches，连续输入不得出现明显掉帧 |
| 扩展内存 | 目标峰值 < 45 MiB；冷启动、模糊音、表情、剪贴板分别测量 |
| 静置能耗 | 5 分钟静置无周期任务；Instruments Energy Log 记录 |
| 连打能耗 | 同亮度、相同设备、相同文本，与系统输入法 / 微信输入法各连续输入 10 分钟对照 |
| 宿主兼容 | 微信、备忘录、Safari、搜索框、邮箱、选区、横屏、切换键盘、完全访问开关 |
| 无障碍 | VoiceOver、减少透明度、减少动态效果、大字体、深色模式 |

## iOS 能力边界

第三方键盘不能读取宿主界面的任意像素，因此不会透过玻璃复制聊天背景。系统材质仅作用于扩展自身可渲染的内容。

剪贴板和共享容器依赖完全访问；本项目不使用因此获得的联网能力。剪贴板也可能触发系统粘贴确认，内容只在用户点击读取后保存。

回车类型是宿主提供的提示。扩展可输入 `\n`，但无法调用所有聊天 App 的私有发送动作；实际是否发送由宿主处理，不承诺强制发送。图片贴纸也无法通用地直接插入消息框，因此使用系统剪贴板并由用户粘贴。

密码框、部分电话输入框或主动禁止第三方键盘的 App 会使用系统键盘。当前主要适配 iPhone；iPad 专用布局和硬件键盘快捷键尚未实现。

参考 Apple 官方文档：[Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)、[UITextDocumentProxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)、[UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect)、[UIGlassContainerEffect](https://developer.apple.com/documentation/uikit/uiglasscontainereffect)、[Liquid Glass 性能建议](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)。

## 工程目录

```text
App/                  SwiftUI 主 App + 实际原生键盘体验区
KeyboardExtension/    系统键盘入口与文本代理
SharedUI/             共用 UIKit 键盘、玻璃、交互与异步候选控制
Core/                 可独立测试的布局、设置、组合状态、离线引擎、剪贴板
Core/Resources/       内置 pinyin.clx / english.clx
Tests/                33 个核心 XCTest 用例
NativeTests/          原生初始化、候选、工具栏、单手与安全区检查
Config/               Info.plist、签名、App Group、隐私清单
Data/                 补充词表、可复现来源与 SHA-256
Scripts/              词库编译、工程生成、数据验证、Mac 构建入口
Design/               可点击设计预览与预览截图
Validation/           本次检查报告及尚未验证的项目
Licenses/             第三方词库许可与修改声明
```

词库与工程重建：`python3 Scripts/build_lexicon.py`、`python3 Scripts/generate_project.py`。只有词库构建工具会访问网络；App 和键盘运行不需要它。词库来源固定到指定提交，当前资源哈希见 `Data/manifest.json`。

## 接下来的开发顺序

先完成签名与 iPhone 安装，再检查宿主兼容性并测量性能和能耗。随后针对真实语料强化拼音切分、模糊音组合、错拼纠正、英文纠错和上下文排序；最后补充可导入词库与贴纸包、iPad 适配和上架准备。当前不是已验证可上架的完成版。
