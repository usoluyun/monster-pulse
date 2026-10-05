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

**尚未达成**的核心目标是「资源占用低于活动监视器」——方向成立但证据不足（只跑了 1 轮，且活动监视器多进程计量有缺陷），另有「关闭窗口后内存涨至约 4 倍」待定性。详见 [验证报告](docs/codex-dock-verification.md)。

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

1. **定性关闭窗口后的内存突增** —— 两轮复现（133 / 135 MB vs 详情打开时 30 MB），直接影响性能验收结论质量。
2. **补满性能验收** —— 修正活动监视器多进程计量（纳入 XPC helper），补满 3 轮重复。完成前不得声称核心目标达成。
3. **低帧率动效** —— 单帧实测 0.042 ms，预算充足。拟表达 CPU 忙闲（亮点流动，速度 ∝ 忙碌率）与额度消耗速率（环形进度亮头爬行）。
4. **Monster 角色视觉** —— 当前图标仍是中性进度条 + 数字，尚未体现「怪兽陪伴」。
5. **系统睡眠与唤醒验证** —— 需真机操作，`willSleep`/`didWake` 无法注入伪造。
