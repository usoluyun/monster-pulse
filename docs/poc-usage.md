# 构建、打包与测试说明

> 本文原为 `example/codex-dock/README.md`（Codex Dock PoC 使用说明）。2026-10-06 PoC
> 转正为项目正式源码，**命令与路径已更新为当前形态**（`app/`、`MonsterPulse`）；
> 下文「验证记录」各节的实测数据属 PoC 阶段历史记录，其中出现的 `CodexDock` 是当时的
> 可执行文件名，保留原样不改写。

原生 Swift + AppKit 小应用：Dock 上显示 Codex 主额度窗口剩余百分比、CPU（青色）与内存估算（紫色）。点击 Dock 图标查看所有返回窗口和重置时间；关闭窗口后常驻，Command-Q 退出。

## 构建与运行

需要 macOS 13+、Xcode Command Line Tools 和支持 `app-server` 的 Codex CLI。请先在终端以 ChatGPT 订阅方式登录 CLI，使用 `codex login status` 确认登录状态。

在项目根目录运行：

```sh
bash app/build.sh
app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse --self-test
app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse --probe
open app/.build/MonsterPulse.app
```

`--self-test` 不联网，验证额度解析、异常数据和真实系统采样。`--probe` 读取当前 CLI 账户的真实订阅额度，成功仅打印百分比、窗口长度与重置时间；不会调用模型或消耗推理额度。网络/登录失败时非零退出，不用模拟数值代替。

应用从 PATH、`~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin` 查找 `codex`。可通过绝对路径指定 CLI（直接启动二进制可保证环境变量传入）：

```sh
CODEX_BIN=/absolute/path/to/codex app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse
```

自检或探针模式在创建 AppKit 应用之前退出。

## 打包

```sh
bash app/build.sh                    # .app（默认）
bash app/build.sh --standalone       # 单个可执行文件，不做 bundle
bash app/build.sh --dmg --sign       # .app 打成 .dmg 并 ad-hoc 签名
bash app/build.sh --universal        # 额外产出 arm64 + x86_64 通用二进制
bash app/build.sh -h                 # 用法
```

产物在 `.build/`（已在 `.gitignore` 中）。

三种产物的差别，以及各自的边界：

| 产物 | Dock 图标 | `open -b` 按 id 启动 | 拷到其他机器直接跑 |
| --- | --- | --- | --- |
| `.app` | 正常 | 可以 | 不行，需签名或手动放行 |
| 单文件 | 正常 | 不行（无 bundle id） | 不行 |
| `.dmg` | 正常 | 可以 | 右键打开，或 `xattr -d com.apple.quarantine` |

单文件产物没有 `Info.plist`，因此没有 `CFBundleIdentifier`，将来也没法挂资源文件。
但 Dock 图标照常显示——因为代码里 `NSApp.setActivationPolicy(.regular)` 强制了激活
策略，不依赖 bundle。适合自用或塞进 dotfiles。

`--sign` 走的是 ad-hoc 签名（`codesign --force --sign -`），不需要证书，但它**不构成
「已公证」**，只解决本机 Gatekeeper 记缓存的问题。

要让别人机器上无需任何操作就能运行，必须走 Developer ID 签名 + Apple 公证，需要付费
开发者账号，流程是：

```sh
# 1. 用 Developer ID Application 证书签名（不是 ad-hoc）
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <你的名字> (<TEAMID>)" MonsterPulse.app

# 2. 提交公证，keychain-profile 需先存在（存的是 App Store Connect API key）
xcrun notarytool submit MonsterPulse.dmg \
  --keychain-profile <PROFILE> --wait

# 3. 盖章，并把公证信息烤进产物
xcrun stapler staple MonsterPulse.dmg
```

`--timestamp` 不能省：没有可信时间戳，Gatekeeper 在离线时会因证书过期而拒绝。
PoC 阶段没必要做这套。

## 行为与限制

- CPU/内存每 5 秒采样，额度每 120 秒查询；手动刷新不会叠加正在执行的查询。
- 每次查询短暂启动一个 Codex 辅助进程，完成或超时后回收。评估开销需计入该进程，不能只看主程序。
- Dock 数字对应 `primary`（没有时为首个有效窗口），详细窗口长度以服务返回为准。
- 查询失败或数据超过 5 分钟时标记 `OLD`，保留最后快照；无数据时显示横线。
- 内存值是 active + wired + compressed physical pages 的近似占比，**不是内存压力或活动监视器“内存已使用”**。
- 没有登录引导或自动修改登录状态；CLI 的认证与自身日志仍由 CLI 管理。
- 应用睡眠时暂停、唤醒后恢复。退出时取消工作并等待辅助进程清理。

## 异常路径测试

`tests/` 下有两个脚本，覆盖查询失败与进程退出两类路径：

```sh
bash app/tests/run-abnormal-tests.sh    # 查询失败：10 个场景
bash app/tests/run-termination-tests.sh # 退出路径：3 条
```

查询失败场景用 `tests/fake-codex.sh` 经 `CODEX_BIN` 注入故障，不改真实登录状态、
不动系统网络，因此不会影响正在运行的 Codex 会话。真实场景另测：未登录用空
`CODEX_HOME` 隔离凭据，断网用指向死代理的包装脚本（只影响该子进程）。

退出路径必须分三条测，因为它们走完全不同的代码：Command-Q 经
`applicationWillTerminate` 优雅取消，SIGTERM **不会**（NSApplication 默认不处理该
信号），SIGKILL 强杀无法回收。

### 2026-10-05 补充：性能对比已跑（1 轮，结论初步）

按 §性能验收方法 采集（`tests/run-perf-test.sh` + `measure.py` + `perf-summary.py`）。
**只跑了 1 轮 15 分钟，未达到文档要求的至少 3 次重复，以下为初步结论。**

| 指标 | CodexDock | 活动监视器 | 占比 | 判定 |
| --- | --- | --- | --- | --- |
| 平均 CPU | 0.34% | 1.80% | 18.8% | 低于，达标 |
| 平均物理内存 | 46.6 MB | 115.3 MB | 40.4% | 低于，达标 |

采样口径：Release(-O) 构建，两者分开单独运行，间隔 60s，累计 CPU 含子进程，
物理内存用 `footprint`（非 RSS，避免共享页重复计入）。

两处必须记录的数据缺陷，使上表尚不足以作为最终结论：

1. **详情关闭场景内存涨到 4 倍。** 详情打开时稳定 30 MB，详情关闭却在约 540s 后稳定在
   133 MB 并保持到结束（15 个采样点里后 6 个都在 133～135 MB）。一次采样不能定性，
   需复现确认是否与 `isReleasedWhenClosed = false` 下窗口对象存活有关。
2. **活动监视器只测到主进程。** `pgrep` 仅取一个 pid，而它是多进程架构（主进程 +
   XPC helper），helper 的 CPU 与内存均未计入。这会**低估活动监视器**、使对比偏向
   CodexDock 有利，因此「内存 40.4%」不可靠；CPU 18.8% 相对可信（主进程通常占大头）。

唤醒次数与能耗仍未采集（需 `powermetrics` + sudo）。

因此「低于活动监视器」这一核心目标目前**方向成立但证据不足**，不能声称已达成：
需要补满 3 轮重复、修正活动监视器的多进程计量、复现内存突增。

### 2026-10-05 补充：draw() 缓存优化与单帧成本实测

`draw()` 拆成两层：静态部分（圆角背景、两条进度条底槽）预渲染成位图，只在 `stale`
或尺寸变化时重建；数字文字按「文本+字号+颜色」缓存成位图，取值域有界（百分比 0…100
加三种标题/空值、两种颜色）。进度条填充保持实时绘制——它形状简单、代价可忽略，
而它才是每 5 秒真正变化的部分。

单帧成本实测（`--draw-bench`，Release -O，Apple Silicon，2000 帧取平均）：

| 场景 | 优化前 | 优化后 | 加速 |
| --- | --- | --- | --- |
| 静止同值 | 0.161 ms | 0.042 ms | 3.8× |
| 数字变化（新字形） | 0.157 ms | 0.041 ms | 3.8× |
| stale 切换（重建背景） | 0.148 ms | 0.041 ms | 3.6× |

**注意这个数字推翻了一个此前的错误估算。** 早前按 `NSString.draw` 的经验值推断
「单帧 1～3 ms、30fps 会吃掉 3%～9% CPU、必然冲破「低于活动监视器」」，实测单帧
只有 0.16 ms（优化前），比估算低一个数量级。按实测换算进程内开销：10 fps 约
0.04%，30 fps 约 0.12%（优化后）。**低帧率动效完全在预算内，不必再自我设限。**

不过 `--draw-bench` 用的是 `cacheDisplay(in:to:)`，**不等于** `dockTile.display()`
的真实路径：真实渲染由系统完成，含 dock tile 上传与 WindowServer 合成，这部分开销
在进程内测不到。帧率预算必须以真实运行的 15 分钟测量为准，不能只信这个基准。

15 分钟实测（与上一轮同条件）：CPU 0.34% → 0.36%，**无改善**。因为当前重绘频率只有
0.2 次/秒（`render()` 有 `lastDockState` 判断，5 秒最多一次），单帧省下的 0.12ms 每 5 秒
摊一次 ≈ 0.002%，完全淹没在噪声里。代价是 bitmap 缓存多占约 3 MB 内存。

结论：**当前 0.2fps 使用模式下这个优化是净负收益**（CPU 没换到、内存加了）。保留它的
理由只为支撑后续动效——高帧率下每帧都要走 `draw()`，那时 3.8 倍加速才有意义。若最终
不做动效，应当回退。

视觉回归（`tests/render-regress.sh` + `tests/pixel-diff.py`）：5 个状态与改前基准
逐像素比对，最大通道差 1/255，差异集中在文字像素（位图预渲染的亚像素舍入），
肉眼不可见。

## 验证记录

2026-10-04，开发环境：Apple Silicon，Swift 6.4，Codex CLI 0.159.3。

- Release 编译成功，应用 Info.plist 校验通过。
- `--self-test` 通过：额度解析、缺失/非法/其他产品额度桶、真实 CPU 和内存采样。
- `--probe` 真实连接成功，返回 300 分钟和 10080 分钟两个额度窗口，正常退出。首次沙箱内执行失败，授权沙箱外运行后成功。
- `.app` 已启动，通过窗口可访问性内容与截图确认真实额度、重置倒计时、CPU、内存估算和刷新按钮正常显示，无文字截断。
- 尚未完成 Dock 图标的独立视觉检查、睡眠/异常/强制终止路径测试、长时间泄漏测试，以及与活动监视器的完整性能对比。不能据此声称资源目标已达成。

> 上面这行是 2026-10-04 的原始记录，**已被下方两节补充覆盖**：异常路径、退出路径与
> 长时间泄漏已于 2026-10-05 实测完毕。仍未完成的是 Dock 图标视觉检查、系统睡眠唤醒，
> 以及与活动监视器的性能对比。

### 2026-10-05 补充：异常路径与退出路径已测

环境：Apple Silicon，Codex CLI 0.160.0。

查询失败 10 个场景全部通过（`run-abnormal-tests.sh`）：基线正常、未登录、子进程
崩溃、永不响应（20.1s 超时生效）、只回 initialize 后挂死（20.2s 超时生效）、混入非
JSON 脏行、响应超 1 MiB（0.6s 即触发大小上限，未空等超时）、延迟响应（9.2s 成功）、
真实未登录、真实断网。错误文案均未泄露凭据或路径。

读层超时与清理均有效：8 个注入场景跑完无残留子进程。

退出路径 3 条（`run-termination-tests.sh`）：

| 路径 | 修复前 | 修复后 |
| --- | --- | --- |
| Command-Q | 通过，辅助进程 1 → 0 | 通过 |
| SIGTERM | **残留 1 个孤儿 codex 进程** | 通过，1 → 0 |
| SIGKILL | 残留 1 个孤儿 | 残留 1 个孤儿（固有，无法修复） |

SIGTERM 原本失败是真实缺陷：`NSApplication` 默认不处理该信号，
`applicationWillTerminate` 里的 `cancelAllOperations` +
`waitUntilAllOperationsAreFinished` 根本没执行，辅助 codex 进程失去父进程后继续存活。
真实 codex 同样是独立进程，会一样泄漏。

**已修复**：`main.swift` 用 `DispatchSourceSignal` 接管 SIGTERM 与 SIGINT 并转发给
`NSApplication.terminate`，让所有退出路径共用同一套清理逻辑。用 DispatchSource 而非裸
signal handler，是因为 `terminate` 会碰 AppKit，不能在信号上下文里调用；source 必须保留
强引用，释放后监听会失效。SIGKILL 无法捕获，强杀后仍需外部清理。

仍未覆盖：系统睡眠与唤醒（`willSleep`/`didWake` 只能由系统真实睡眠时发出，无法注入
伪造，需真机操作）。

### 2026-10-05 补充：长时间泄漏已测

30 分钟连续运行，31 个采样点（`tests/run-leak-test.sh`，分析见 `tests/trend.py`）：

| 指标 | 首次 | 末次 | 每小时变化 | 判定 |
| --- | --- | --- | --- | --- |
| 物理 footprint | 29.0 MB | 30.0 MB | +41 KB | 平稳 |
| RSS | 113.6 MB | 120.1 MB | +203 KB | 平稳 |
| 线程数 | 11 | 8 | 0 | 平稳 |
| 文件句柄 | 8 | 8 | 0 | 恒定 |
| 辅助 codex 进程 | 0 | 0 | 0 | 恒定 |

RSS 的增长几乎全部发生在头 60 秒（95 → 113 MB，属首帧绘制与首次额度查询的预热），
之后 29 分钟只涨 6.4 MB 并完全走平。文件句柄恒定 8 是最强信号：5 秒采样与 120 秒
轮询各自新建并释放 `Pipe`/`Process`，若句柄随轮询次数累积，这条会单调上升。

覆盖 15 次完整 120 秒额度轮询周期，未见累积。两类定时器（5s 指标采样、120s 额度轮询）
长时间运行无泄漏。

一处说明：`辅助 codex 进程` 全程为 0 不代表没启动过——它每次只活 1～2 秒，60 秒采样
大概率错过。子进程回收由异常路径测试的残留检查证明（8 个场景跑完无残留），两者互补。

详细分析及性能验收流程：[方案文档](codex-dock-feasibility.md)。
阶段性验证结论（各项实测数据、数据缺陷、结论边界、方法论与踩坑记录）：
[验证报告](codex-dock-verification.md)。
