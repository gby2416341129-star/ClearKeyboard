# 澈 · ClearKeyboard

面向中文和英文的原生 iPhone 输入法，当前版本 **0.1.4 开发预览**。包含 SwiftUI 设置 App、UIKit 系统键盘扩展、离线词库和交互设计预览。

**已生成未签名 IPA。** [GitHub 云构建](https://github.com/gby2416341129-star/ClearKeyboard/actions/runs/39014902378) 使用 Xcode 26.6 / iPhoneOS 26.5，主 App 和键盘扩展均通过 Release arm64 真机目标编译，47 个 Swift 核心测试全部通过。18 项原生运行测试全部通过，并已检查浅色、深色、单手和候选截图。安装前仍需签名；具体记录见 `Validation/native-build.json`，iPhone 真机切换、性能与耗电仍待验证。

IPA 打包入口已提供：参见 [BUILD-IPA.md](BUILD-IPA.md)。可推送至 GitHub 的 `main` 分支自动构建、手动运行工作流，或在 Mac 执行 `bash Scripts/build-ipa.sh`；只有真机编译通过后才会生成包含键盘扩展的未签名 IPA，安装前仍需签名。

## 布局与设计

字母采用 iOS 系统式 QWERTY：第一排 10 键、第二排 9 键并左右缩进、第三排 Shift / Z–M / 删除。数字和符号保持系统式页序、位置关系，底排保留 123 / 地球 / 空格 / 回车，并在空格右侧增加常驻中 / EN 切换键。

按键的字符顺序不开放重排，以遵循最新确认的系统布局要求。可自定义按键高度、任意 RGB 颜色、玻璃遮罩浓度、工具栏顺序与显隐、左右单手宽度。系统扩展由 iOS 绘制外层材质及轮廓，内部不再套第二层圆角底板；App 体验区采用 28 pt 连续圆角。输入视图明确向系统报告所需高度，按实际内容区域排布四排按键，避免重复扣除底部安全区而挤扁按键。

- `Design/preview.html`：可直接在浏览器打开；不需要安装依赖或联网。
- `Design/preview-desktop.png` / `preview-phone.png`：已检查的设计预览。
- 设计预览使用少量示例候选。原生 App 的体验区和系统扩展共用完整 Swift 输入引擎与键盘视图。
- 原生 App 自动适应深浅色；HTML 预览展示浅色设计。

## 0.1.4 修正

移除键盘内层的不透明背景、彩色假底板和第二套轮廓。扩展使用透明内容视图与系统 `UIInputView.Style.keyboard` 材质，iOS 26 按键继续使用原生 Liquid Glass；App 体验区只保留一层背景材质。模拟器的玻璃截图确实显示了按键后方的测试文字与颜色；微信、Safari 等跨进程宿主的背景呈现仍需真机复测。低电量、减少透明度或选择纯净材质时，会按设置使用实色。

键盘根视图实现自适应尺寸接口，工具栏与候选共用 44 pt 顶部区域，四排按键随实际高度排布。中文键帽统一大写 QWERTY，输入框中的待确认拼音与英文大小写逻辑保持独立。空格右侧保留中 / EN 快捷切换，左右单手模式的侧栏和工具栏也能使用。

整套图标改为小尺寸彩色对象：蓝色纸张剪贴板、金色表情、蓝银键盘、多色调色板与分组工具；去掉大彩色底圈和白色符号的旧方案。主 App、工具面板、工具栏和品牌使用一致的图形，快捷工具仍支持增删、拖动排序，并在左右手模式共用设置。

中文仍通过公开标记文本接口在宿主输入框显示拼音、在键盘顶部显示中文候选。长串简拼加入逐段组合和增量路径缓存，组合长度提高到 256 个有效字母；核心回归覆盖连续 80 键的 `hd` 简拼、75 键全拼及全拼与简拼混输，原生模型验证连续 40 键仍有完整中文候选。这是词典与规则引擎，长句语义、错拼纠正和候选质量还需持续改进。

长按空格约 350 ms 进入光标模式。移动保留小数距离，每 4.5 pt 累积为一个步进，按屏幕刷新节奏合并宿主光标调用；移动期间停止候选查询和逐步界面重绘，松手或取消后只刷新一次。刷新循环只在手势期间存在；模拟器验证状态与调用次数，实际手指延迟和跨行体验尚未测量。

删除键支持上滑清空、下滑撤回，保留点按删除和长按连续删除；提示区分清空与撤回，切换输入框后旧内容不可恢复到新输入框。App 体验区可恢复全文及原选区；系统扩展仅操作公开文本代理提供的上下文，单次上限 4,096 字，无法保证删除宿主未提供的长文本，也不能恢复非空选区或撤回已发送消息。

输入 `99x88` 自动显示 `8712` 和 `99x88=8712` 两个候选，点击后替换算式。支持数字页与字母页切换、常见四则运算、括号、小数和运算优先级；使用有界本地解析器，无 `eval`、联网或独立计算器页面。

剪贴板在界面活动时自动收录文字、链接、图片和可读取的小附件；使用复制变更通知及界面激活检查，没有轮询。新增系统粘贴按钮 `UIPasteControl`，接收系统提供的数据而不再次读取剪贴板。输入设置中提供“系统设置 → 澈 → 从其他 App 粘贴 → 允许”的一次设置说明与入口；键盘还需要完全访问。系统许可由用户在 iOS 设置中控制，App 无法代为授权；App 和扩展均暂停期间不能记录每一次复制，下一次激活仅能收录当时的最新内容。

默认保留 7 天，可选择 15 分钟、1 小时、1 天、7 天、30 天或永久，也可关闭自动收录。最多 200 条、每条文字 2,000 字、固定 10 条；附件每条最多 8 MiB、合计 32 MiB，按内容哈希去重并单独存储。永久取消时间过期，仍有容量限制；到期清理在访问时执行。图片和附件点按复制后由用户在宿主粘贴，公开文本代理无法直接插入任意文件。

按键字符按可见字形轮廓居中，Shift、删除和地球键保留清晰的系统符号。颜色可使用系统取色器、HEX 和键盘 RGB 滑杆自由调整。原生截图、测试范围和真机待测项目见 [Validation/STATUS.md](Validation/STATUS.md)，反馈处理逐项见 `Validation/feedback-resolution.json`。

## 已实现的源码能力

| 能力 | 当前实现 |
| --- | --- |
| 原生扩展 | `UIInputViewController`，标准地球键与系统键盘选择菜单 |
| 玻璃 | iOS 26 原生 `UIGlassEffect`；iOS 18–25 系统材质；清透 / 柔雾 / 纯净、浓度；系统取色器、HEX 和键盘 RGB 滑杆，预设色作为快捷入口 |
| 中文输入 | 拼音在宿主标记、候选在键盘顶部；65,137 个词条；全拼、简拼混合词句组合、增量缓存、256 字母组合、局部选词；中文键帽大写 |
| 英文输入 | 50,000 个词条，前缀补全、有限常用续词、大小写继承、句首大写 |
| 模糊音 | z/zh、c/ch、s/sh、n/l、f/h、an/ang、en/eng、in/ing；按组开关、最多 12 个变体 |
| 预测 | 中文词条前缀续词；英文有限常用搭配；可关闭续词 |
| 选词学习 | 默认关闭；本地已选词计数，最多 512 条；延后写入；清除后旧进程不会回写被清除数据 |
| 单手 | 左 / 右 / 标准；工具栏随键盘靠边；侧栏换手、调整尺寸、一键恢复；宽度 68%–88% |
| 编辑 | 英文双击 Shift 锁定大写；长按删除、上滑清空 / 下滑撤回；长按空格按帧合并光标移动 |
| 算式 | 常见四则运算自动结果候选，如 `99x88` → `8712` / `99x88=8712` |
| 工具栏 | 最多三个快捷工具；在键盘内增删、拖动排序；所有模式共用设置，中 / EN 常驻空格旁，一键切换 |
| 剪贴板 | 文字、链接、图片和小附件自动收录；系统粘贴按钮；7 天 / 永久等期限；最多 200 条，单附件 8 MiB、总附件 32 MiB |
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
- iOS 26 按键使用独立原生玻璃表面，通过一个 UIGlassContainerEffect 容器统一合成；工具栏使用缓存的彩色图标。输入时不重建全部按键或材质。此方案的实际 GPU 开销仍需真机测量。
- 无静置刷新循环、后台剪贴板轮询或逐帧玻璃动画。光标显示同步仅在空格手势期间运行；删除计时器仅在长按期间运行，隐藏时停止。
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

扩展使用系统键盘材质并保持内容视图透明，不截图或读取宿主界面的任意像素。背后的哪些内容能参与材质合成由 iOS 和宿主决定；目前已验证同进程 UIKit 文字与颜色背景，尚未验证微信、Safari 等跨进程宿主，不能将此截图当作所有 App 透视效果的证明。

剪贴板和共享容器依赖完全访问；本项目不使用因此获得的联网能力。自动读取受 iOS 粘贴许可控制，设置为允许后才可避免重复询问；系统粘贴按钮用于用户明确发起的粘贴，不代替后台自动收录许可。

回车类型是宿主提供的提示。扩展可输入 `\n`，但无法调用所有聊天 App 的私有发送动作；实际是否发送由宿主处理，不承诺强制发送。图片贴纸也无法通用地直接插入消息框，因此使用系统剪贴板并由用户粘贴。

密码框、部分电话输入框或主动禁止第三方键盘的 App 会使用系统键盘。当前主要适配 iPhone；iPad 专用布局和硬件键盘快捷键尚未实现。

参考 Apple 官方文档：[Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)、[UITextDocumentProxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)、[UIInputView 材质](https://developer.apple.com/documentation/uikit/uiinputview/style/keyboard)、[自适应高度](https://developer.apple.com/documentation/uikit/uiinputview/allowsselfsizing)、[UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol)、[UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect)、[UIGlassContainerEffect](https://developer.apple.com/documentation/uikit/uiglasscontainereffect)、[Liquid Glass 性能建议](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)。

## 工程目录

```text
App/                  SwiftUI 主 App + 实际原生键盘体验区
KeyboardExtension/    系统键盘入口与文本代理
SharedUI/             共用 UIKit 键盘、玻璃、交互与异步候选控制
Core/                 可独立测试的布局、设置、组合状态、离线引擎、剪贴板
Core/Resources/       内置 pinyin.clx / english.clx
Tests/                47 个核心 XCTest 用例
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

公开接口参考：[标记拼音](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)、[剪贴板变更通知](https://developer.apple.com/documentation/uikit/uipasteboard/changednotification)、[剪贴板读取提示](https://developer.apple.com/documentation/uikit/uipasteboard)。
