# Monster Pulse · 怪兽脉搏

Dock 上的 AI 额度与系统状态监测器。

Monster Pulse 是一个面向 macOS 的轻量原生应用：常驻 Dock，让你一眼看到 Codex 订阅额度、CPU 忙闲与内存占用，并通过详情窗口查看额度窗口和重置时间。

## 产品方向

- **一眼即知**：优先展示 AI 额度，兼顾系统状态。
- **轻量常驻**：采用 Swift + AppKit，无第三方依赖，减少后台采样与绘制开销。
- **怪兽陪伴**：延续 Monster 产品命名风格，探索以小怪兽及轻量动效表达状态。
- **如实展示**：明确区分有效、过期与不可用数据。

## 当前状态

PoC 已转正为本项目的正式源码，位于 `app/`。可执行文件由 `CodexDock` 改名为 `MonsterPulse`，bundle id 为 `local.monsterpulse`。

功能上暂无变化：仍是 Codex 额度 + CPU + 内存三项。初期聚焦 Codex 订阅额度；后续可探索更多 AI 工具的额度与状态。

**核心目标「资源占用低于活动监视器」已于 2026-10-06 达成**：3 轮重复、修正全部计量缺陷、
动效开启的条件下，平均 CPU 为活动监视器的 29.5%、平均物理内存为 14.0%。此前记录的两处
数据缺陷（父子 footprint 求和、活动监视器多进程计量）均已修正。唤醒次数与能耗仍未采集。

已实现：详情窗口结构化布局、Dock 右键菜单、可配置刷新频率与显示项、额度预警（Dock 图标跳动）、
低帧率动效（额度时间进度轨 + CPU 活动亮点）。

## 目录

```text
monster-pulse/
├── README.md
├── app/           # 应用源码（Swift + AppKit）、构建脚本与测试资产
│   ├── Sources/
│   ├── tests/
│   ├── Info.plist
│   └── build.sh
└── docs/          # 产品定位、设计方案与验证记录
```

## 快速开始

需要 macOS 13+、Xcode Command Line Tools；读取真实额度另需支持 app-server 的 Codex CLI，并以 ChatGPT 订阅方式登录。

```sh
bash app/build.sh
app/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse --self-test
open app/.build/MonsterPulse.app
```

## 文档

- [文档入口](docs/README.md)
- [可行性方案与 PoC 设计](docs/codex-dock-feasibility.md)：产品范围、数据来源、技术实现与性能验收方法。
- [阶段性验证报告](docs/codex-dock-verification.md)：异常查询、退出清理、长期运行、绘制成本及待解决问题。
- [构建、打包与测试说明](docs/poc-usage.md)

`docs/` 下的文件名与内容保留 `codex-dock` 历史命名，因为它们是 PoC 阶段的原始记录，改名会破坏可追溯性。

## 后续重点

按优先级：

1. **Monster 角色视觉** —— 当前图标仍是中性进度条 + 数字，尚未体现「怪兽陪伴」这一产品方向。建议在动效基础上做，两者会同时改 `draw()`。
2. **唤醒次数与能耗** —— 性能验收唯一未覆盖项，需 `powermetrics` + sudo。
3. **系统睡眠与唤醒验证** —— 代码已实现但从未实测，`willSleep`/`didWake` 无法注入伪造，需真机操作。

已完成：关闭窗口内存突增定性（§6.1，实为计量口径问题）、低帧率动效、性能验收 3 轮、Dock 右键菜单人工点验、开机自启。

## 开机自启

设置面板 → 「启动」分组。实现走 `SMAppService.mainApp`，**ad-hoc 签名下实测可用，不需要
Developer ID**——曾经写成「需有效签名」，那是从系统通知的失败类推来的，未实测，是错的。

两条设计要点：

- **事实源是系统状态，不是本地配置。** 用户也能在「系统设置 → 通用 → 登录项」里改，
  所以面板里的勾选只是系统状态的显示，每次打开都重读 `SMAppService.status`。
  勾选后无论注册成功与否都重读一次，失败时勾选会被纠正回真实值。
- **状态分四档**，文案不同：`enabled` / `requiresApproval`（还需用户去系统设置放行）/
  `notRegistered` / `notFound`（`--standalone` 形态无 bundle id，功能置灰）。

配合自启，额度轮询默认从 2 分钟放宽到 **5 分钟**：应用整天常驻，每次查询都要 spawn
一个 codex app-server 子进程，120 秒是一天 720 次。额度本身变化慢——5 小时窗口里用掉
20% 通常要一小时以上。仍可在设置面板自行调回。
