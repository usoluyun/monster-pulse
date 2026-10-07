# Monster Pulse · Agent 规则

本文是**项目级**规则，只针对 Monster Pulse。全局通用规则见
`~/.config/opencode/AGENTS.md`（chezmoi 纳管，不在本仓库）。

## 项目是什么

macOS Dock 常驻小应用：显示 Codex 订阅额度、CPU 忙闲、内存与磁盘 I/O。
Swift + AppKit，零第三方依赖。`app/` 是全部源码，`app/Sources/` 分四层：

| 文件 | 职责 |
|---|---|
| `Metrics.swift` | 领域层：额度解析、Codex 子进程查询、系统采样、格式化。只依赖 Foundation |
| `Alerts.swift` | 预警规则与跃迁去重。纯逻辑，不碰 AppKit |
| `Config.swift` | 配置读写 + 设置窗口 |
| `DetailsView.swift` | 详情窗口视图 |
| `main.swift` | 应用生命周期、Dock 图标、自检与渲染夹具 |

分层原则：**逻辑必须在不依赖 AppKit 的地方**，这样 `--self-test` 才能在创建
NSApplication 之前跑完。

## 构建与验证

```sh
bash app/build.sh                      # Release(-O)，产物在 app/.build/
app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse --self-test
bash app/tests/render-regress.sh       # 视觉回归（25 个用例，容差 24）
bash app/tests/run-abnormal-tests.sh   # 查询失败 10 场景
bash app/tests/run-termination-tests.sh # 退出路径 2 条
bash app/tests/run-perf-test.sh        # 性能验收（3 轮，约 75 分钟）
```

离屏渲染（改 UI 后**必须实际看图**，不能只看测试通过）：

```sh
app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse --render-test <out.png> 62 0.42 0.61 none both "pace=0.45,activity=0.8"
app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse --details-render-test <out.png> normal
app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse --settings-render-test <out.png> full
```

---

# 验证纪律（重要，以下每条都是实际踩过的坑）

> 这八条不是预防性_best practice_，是本项目实际付出过代价换来的。
> 第 1、2、3 条是同一类错误的三个侧面：**我制造了一个自己的环境，然后在里面验证**——
> 终端代替 Dock 启动、content.frame 代替窗口实际尺寸、自己写的值代替最终生效的值。

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

---

# 环境约束

- **本机只有 Command Line Tools**（`xcrun --show-sdk-path` 指向
  `/Library/Developer/CommandLineTools`）：没有 Xcode、没有离线文档、没有模拟器。
  任何 Apple API 查询都必须联网。SDK header 在本地可直接读。
- **Apple 官方文档要用 `.md` 端点**，网页是 JS 渲染的抓不到内容：
  `https://developer.apple.com/documentation/appkit/nswindow/isreleasedwhenclosed.md`。
  大小写规则不统一且无推导规律，须传 Swift 源码里的原始符号名，404 再试全小写。
  详见 chezmoi 的 `apple-docs` skill。
- **离屏渲染必须钉死外观**：视图不在窗口里时 `labelColor` 等动态颜色解析不出来，
  文字被画成白色，而窗口背景跟随系统外观也是白色，白字白底——浅色下渲染出的
  PNG 一个字都没有。三个 `--*-render-test` 都已钉 `darkAqua`。
  **注意别用「每次先 --update 重建基准图」掩盖外观变化**，那样这个依赖永远发现不了。
- **CPU tick 计数器约每秒才更新一次**（实测零增量比例：10ms 为 13/15、200ms 为
  6/15、1000ms 为 0/15）。任何短于 1 秒的 CPU 采样都拿不到值，别为此设计动效。
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
- **视觉设计暂缓**（用户 2026-10-06 决定）。Dock 静止尺寸是 43pt，实测当前只有
  额度数字真正可读，标题与进度轨基本不可见——真要做需先定可读性预算。
- 内存压力等级（`kern.memorystatus_vm_pressure_level()`）**公开拿不到**：无 SDK
  header 且符号未导出；`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` 是公开 API 但只在
  状态变化时通知，不能用于显示。
- **跑本地大模型时的负载在 GPU 侧**，实测推理时 GPU 100% 而 CPU 仅 6–17%、
  磁盘归零。GPU 走 `GPUSampler`（IOKit 的 `IOAccelerator` → `PerformanceStatistics`），
  **这是未文档化接口，键名无兼容性保证**，读取失败必须返回 nil 而不是猜测。
  实测 service 缓存后单次读约 43–59 微秒、不需要 sudo。**未加 GPU 满载预警**
  （浏览器/视频常年接近满载，默认预警噪音太大）。
