# Monster Pulse · Agent 规则

本文是**项目级**规则，只针对 Monster Pulse。全局通用规则见
`~/.config/opencode/AGENTS.md`（chezmoi 纳管，不在本仓库）。

## 项目是什么

macOS Dock 常驻小应用：显示 Codex 订阅额度、CPU、GPU、内存与磁盘 I/O。
Swift + AppKit，零第三方依赖。`app/` 是全部源码，`app/Sources/` 的分工：

| 文件 | 职责 |
|---|---|
| `Metrics.swift` | 领域层：额度解析、Codex 子进程查询、系统采样（CPU/内存/磁盘/GPU）、格式化。**不 import AppKit** |
| `Alerts.swift` | 预警规则与跃迁去重。纯逻辑，不碰 AppKit |
| `Config.swift` | 配置读写 + 设置窗口 |
| `DetailsView.swift` | 详情窗口视图 |
| `main.swift` | 应用生命周期、Dock 图标、自检与渲染夹具 |

分层原则：**领域逻辑与预警逻辑必须放在不 import AppKit 的文件里**，这样
`--self-test` 才能在创建 NSApplication 之前跑完全部断言。

注：`Metrics.swift` 还 import 了 `Darwin`（mach 采样）与 `IOKit`（GPU 采样），
两者都是纯 C 接口，不需要 AppKit 运行时。

## 构建与验证

```sh
bash app/build.sh                      # Release(-O)，产物在 app/.build/
app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse --self-test
bash app/tests/render-regress.sh       # 视觉回归（28 个用例，容差 24）
bash app/tests/run-abnormal-tests.sh   # 查询失败 10 场景
bash app/tests/run-termination-tests.sh # 退出路径 2 条
bash app/tests/run-perf-test.sh        # 性能验收（3 轮，约 75 分钟）
```

命令行模式（均在创建 AppKit 应用之前退出）：

| 模式 | 用途 |
|---|---|
| `--self-test` | 全部纯逻辑断言，不联网。系统采样会等计数器变化，最长约 1 秒 |
| `--probe` | 读真实额度，单次。非零退出即失败，不用模拟值代替 |
| `--render-test` | Dock 图标离屏渲染，用法 `<out> <beats> <rails> <meters> <phase>`：beats=三个 0~100 忙碌等级（-1 不画该点），rails="used/elapsed,…"（none=无轨），meters=both/no-cpu/no-gpu/no-both，phase=心跳相位 |
| `--details-render-test` | 详情窗口离屏渲染：`normal` / `no-data` / `stale` / `error` / `loading` / `*-no-meters` / `no-gpu` |
| `--settings-render-test` | 设置面板离屏渲染，并输出 `layout:` 诊断（`render-regress.sh` 据此判 FAIL）。状态：`proxy` / `dns` / `nometers` / `alerts-off` / `login-on` / `login-off` / `full` |
| `--dock-menu-dump` | 打印 Dock 菜单的启用态、标题与 action 选择器，人工点验时的对照依据 |
| `--draw-bench` | 单帧 draw 成本微基准 |

离屏渲染（改 UI 后**必须实际看图**，不能只看测试通过）：

```sh
APP=app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse
$APP --render-test <out.png> 62 0.42 0.61 none both "pace=0.45,activity=0.8"
$APP --details-render-test <out.png> normal
$APP --settings-render-test <out.png> full
```

诊断通道：`MP_SAMPLE_LOG=/tmp/x.csv` 时逐次采样落盘（默认关闭——每 5 秒写盘是
真实开销且日志无上限）。`app/tests/mem-probe.sh` 是详情窗口开/关的对照实验。

---

# 验证纪律（重要，以下每条都是实际踩过的坑）

> 这九条不是预防性_best practice_，是本项目实际付出过代价换来的。
> 第 1、2、3 条是同一类错误的三个侧面：**我制造了一个自己的环境，然后在里面验证**——
> 终端代替 Dock 启动、content.frame 代替窗口实际尺寸、自己写的值代替最终生效的值。
> 第 9 条是另一类：**借用另一个功能的实测结论**。

## 1. 验证场景必须匹配真实使用场景

**GUI 启动的应用与终端里的进程，环境完全不同。** 从 Dock/Finder 启动的应用
不经过 shell、不读 `.zshrc`，因此没有 `http_proxy`/`https_proxy`/`all_proxy`。

同一个 bug 的两种表现：终端跑 `--probe` 一直成功（继承 shell 代理），用户从
Dock 启动就永远查询超时。**我在终端验证了很多轮，方向完全错了**，直到用户报告
「刷不到用量」才定位到环境继承。

规则：涉及「用户怎么用这个应用」的问题，一律从 Dock 启动验证，不要用终端代替。

## 2. 离屏渲染不等于真窗口

`NSWindow` 会用窗口尺寸**强制覆盖** contentView 的 frame。所以直接写
`contentView.frame = …` 不会让窗口变高——窗口显示时会把它压回去。

这个 bug（设置面板内容需要 528pt，窗口只有 480pt，顶部两项被裁掉）**离屏渲染
完全看不出来**，因为渲染按 content 的 frame 走，恰好是「算对了」的那个高度。
是用户打开应用才发现的。

规则：

- 判窗口内容区够不够高，用 `window.contentLayoutRect.height`，**不要**用
  `contentView.bounds.height`（后者读的是自己刚赋的值，测不出问题）。
- 改窗口尺寸必须走 `window.setContentSize(_:)`。
- `--settings-render-test` 会输出 `layout:` 诊断行，`render-regress.sh` 把
  「不足(顶部被裁)」判为 FAIL。改布局后如果这行报警，别绕过去。

## 3. 「赋值成功」不等于「生效」

判据必须取自**最终生效的对象**，不能取自自己刚写入的那份。上面第 2 条就是
反例：`contentView.frame` 读出来是对的，问题出在窗口把它覆盖了。

同理：不要用「我改了某个值」推断「行为变了」，要找**系统最终使用的那个值**。

## 4. 视觉检查必须真的看图

测试全绿不等于界面对。以下两处问题都是先渲染出来**用眼睛看**才发现的，
自动化检查当时都没报：

- 额度时间进度参考线画在了 CPU 条上（Dock 图标里额度用大字表示，没有独立进度条，
  标在 CPU 条上会被误认为与 CPU 有关）
- 设置面板行距错乱、提示文字被截断（「标签+滑杆」同行用负 gap 表达，而高度累加
  对负 gap 取 `max(0, …)`，每个滑杆行多算一倍高度）

规则：改 `draw()` 或视图布局后，把渲染结果调出来看，别只跑测试。

## 5. 视觉回归要断言语义判据，不能只靠快照

快照只能告诉你「变了」，不能告诉你「变错了」。所以除了逐像素比对，还要断言
语义条件——例如设置面板的 `layout:` 诊断必须报告「足够」，而不只是「和上次一样」。

「够高」和「留白摆对了位置」是两件事。设置面板曾一直缺顶部内边距：
`layoutRows()` 从 `content.bounds.height` 起排，首行被顶到内容视图最上沿，
24pt 内边距整份挪到了底部变成死白。原有诊断只查「需要多少 / 提供多少」，
判「足够」，所以一直没发现——**判据要覆盖出错的那个维度**，不能只查自己想到的
那个。现在诊断额外报「顶部留白」并要求接近 inset。

同理，视觉基准图**必须由当前构建生成**，容差 24（CoreText 抗锯齿跨编译抖动约
22/255；同一二进制两次渲染差异为 0）。容器输入固定化，不要用 `Date()`。

## 6. 夹具要走真实函数，不要写死字面量

曾经把倒计时文案写成字面量 `"3 小时 12 分后"`，导致 `countdown()` 在视觉回归里
**完全不被执行**——把函数改成永远不出分钟，回归仍然全过。改成传固定时间戳走
真实函数后，同一处改动被判 3 个 FAIL。

规则：夹具传原始数据，让被测函数自己算出结果。

## 7. 渲染夹具不许有持久化副作用

`--settings-render-test` 曾用 `config.setShowCPU(…)` 构造夹具，而那些 setter 会
写 UserDefaults——跑一次渲染就改掉用户真实配置。改用成员初始化。

## 8. 自检失败要能看到「是哪一条」

用 `precondition` 会 SIGTRAP 且 stderr 不冲刷，排查时只拿到空白。改成收集式
断言：跑完全部用例后汇总输出，退出码 1。

## 9. 每个功能要单独验证，不能拿 A 的证据当 B 的

我曾断言「开机自启和系统通知是同一签名约束，都需 Developer ID」，并把这句写进
AGENTS.md、README、验证报告和待办。**这条结论从未实测**——它是从通知的实测
结果类推来的（通知确实失败：ad-hoc 签名下 `requestAuthorization` 返回
`granted=false` + `UNErrorDomain Code=1`）。用户质疑后实测发现：

| 能力 | ad-hoc 签名 | 证据 |
| --- | --- | --- |
| `UNUserNotificationCenter` | 不可用 | 实测授权失败 |
| `SMAppService.mainApp.register()` | **可用** | 实测 status 由 `notFound` 变为 `enabled` |

「同一约束」「应该同样受限」这类说法尤其危险：它听起来像结论，实际上是
一次没有执行的实验。**签名、权限、沙箱这类要求逐能力独立实测，不要互相类推。**

规则：写进 AGENTS.md / 报告的任何能力判断，必须能指回一次真实执行；
指不回去就标注「未验证」，不要用类推填空。

---

# 环境约束

- **本机只有 Command Line Tools**（`xcrun --show-sdk-path` 指向
  `/Library/Developer/CommandLineTools`）：没有 Xcode、没有离线文档、没有模拟器。
  任何 Apple API 查询都必须联网。SDK header 在本地可直接读。
- **Apple 官方文档要用 `.md` 端点**，网页是 JS 渲染的抓不到内容：
  `https://developer.apple.com/documentation/appkit/nswindow/isreleasedwhenclosed.md`。
  大小写规则不统一且无推导规律，须传 Swift 源码里的原始符号名，404 再试全小写。
  详见 chezmoi 的 `apple-docs` skill。
- **离屏渲染要同时钉外观和背景色**，两件事缺一不可：
  - **钉外观**：视图不在窗口里时 `labelColor` 等动态颜色解析不出来，文字被画成
    白色，而窗口背景跟随系统外观也是白色，白字白底——浅色下渲染出的 PNG 一个字
    都没有。三个 `--*-render-test` 都已钉 `darkAqua`。
  - **垫背景色**：`NSWindow` 的 contentView 若 `wantsLayer` 且没有自己的底色，
    `cacheDisplay` 出来的位图背景是**透明**的。真实窗口里窗口自己垫了
    `windowBackgroundColor` 所以看不出来，离屏没有窗口就穿帮了。
    `renderToPNG` 现在显式设 `content.layer?.backgroundColor`，且必须在设完
    appearance **之后**取 `cgColor`，否则动态色按当时的当前外观解析，等于白垫。
    （`DetailsView` 在 `draw()` 里自己填底色，所以它天然没事。）
- **`main.swift` 顶层全局量必须声明在使用之前。** 顶层代码按顺序执行，
  `renderAppearance` 原先声明在文件中部而 `--settings-render-test` 在它之前就读，
  拿到的是 nil——编译器不报错，只有真渲染才看得出。更坑的是它**掩盖了上面那个
  背景色 bug**：appearance 为 nil 时文字按系统外观成深色，深字配透明底反而
  「能看见」，于是基准图一直是错的却没人发现。**一个 bug 挡住另一个 bug 时，
  先确认前一个是不是真的不存在。**
- **视觉基准图不该依赖机器真实状态。** 开机自启勾选原先直接读
  `SMAppService.status`，于是「用户开没开自启」「跑的是 `.build` 还是
  `/Applications`」都会让基线漂移。现在一律由夹具注入固定值。
  **注意别用「每次先 --update 重建基准图」掩盖外观变化**，那样这个依赖永远发现不了。
- **CPU tick 计数器约每秒才更新一次**（实测零增量比例：10ms 为 13/15、200ms 为
  6/15、1000ms 为 0/15）。任何短于 1 秒的 CPU 采样都拿不到值，别为此设计动效。
- **`systemUptime` 只在 CPU 真正运行时推进，跨睡眠不涨**（实测两次，Clamshell Sleep）：
  776s 墙钟 → 181.7s uptime（23%）；1170.7s → 64.5s（5.5%）。**拿它当时间分母，
  在任何跨睡眠的区间上都会严重偏小**——磁盘速率会低估约 18 倍。算速率要用
  `Date()` 的墙钟差，不是 uptime 差。
- **`pageins`/`pageouts` 是亚秒级更新的**，可算磁盘 I/O 速率；已实测读 684MB
  文件时换算出 4489 MB/s，与实际 4493 MB/s 吻合。但它只反映**首次加载**的突发，
  文件进页缓存后就不再增长。
- **ad-hoc 签名下不可用**：系统通知（`UNUserNotificationCenter`）——实测
  `requestAuthorization` 恒定返回 `granted=false` + `UNErrorDomain Code=1`。
  本机 0 个有效签名身份。
- **`SMAppService` 开机自启在 ad-hoc 签名下可用**（2026-10-07 实测纠正）：
  `SMAppService.mainApp.register()` 成功，status 由 `notFound` 变为 `enabled`。
  我曾按通知的结论类推「同一约束」，**未实测就写进文档，是错的**。
  通知与开机自启的签名要求不同，不要互相类推。

# 决策记录

- **Codex 代理由用户在设置面板手填，不用 `launchctl setenv`**（用户 2026-10-06 决定）。
  别再提议改成 launchctl 方案。
- **额度预警用 Dock 图标跳动，不用系统横幅通知**（同上）。理由是可测的：横幅通知
  在 ad-hoc 签名下授权恒定失败，且无 bundle 时 `current()` 抛的 ObjC 异常
  Swift 接不住，会让 `--standalone` 产物崩溃。
- **视觉设计暂缓**（用户 2026-10-06 决定）。Monster 角色形象仍暂缓。
- **Dock 图标 = 心跳点 + 额度轨 + 计量条，标题与大数字撤掉**（用户 2026-10-07
  定稿，是对上一版「纯点阵」的修正——我误把「加点」理解成「只留点」，用户澄清
  进度条保留）。三个心跳点（CPU 青 / GPU 绿 / 额度 琥珀）横向排在上方带区，
  **跳速映射忙碌度**（0.35–2 Hz）；下方保留额度轨 ×2（bullet graph）与 CPU/GPU
  计量条。数字信息在右键菜单与详情窗口。
  额度点的忙碌度用**消耗速率**（相邻两次查询的用量差 ÷ 时间差，相对线性 pace，
  2 倍线性 = 满心跳），不用存量（used%）——存量是「用了多少」，速率才是「在不在忙」。
  曾试过用「消耗超前时间进度」（used% − elapsed%），那是报警语义：上午猛用一波、
  下午停手，点还会跳几个小时，和 CPU/GPU 点的繁忙语义不一致。
- 内存压力等级（`kern.memorystatus_vm_pressure_level()`）**公开拿不到**：无 SDK
  header 且符号未导出；`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` 是公开 API 但只在
  状态变化时通知，不能用于显示。
- **跑本地大模型时的负载在 GPU 侧**，实测推理时 GPU 100% 而 CPU 仅 6–17%、
  磁盘归零。GPU 走 `GPUSampler`（IOKit 的 `IOAccelerator` → `PerformanceStatistics`），
  **这是未文档化接口，键名无兼容性保证**，读取失败必须返回 nil 而不是猜测。
  实测 service 缓存后单次读约 43–59 微秒、不需要 sudo。**未加 GPU 满载预警**
  （浏览器/视频常年接近满载，默认预警噪音太大）。
