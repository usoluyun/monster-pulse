# Monster Pulse · 怪兽脉搏

Dock 上的 AI 额度与系统状态监测器。

Monster Pulse 是一个面向 macOS 的轻量原生应用：常驻 Dock，让你一眼看到 Codex 订阅额度、CPU 忙闲与内存占用，并通过详情窗口查看额度窗口和重置时间。

## 产品方向

- **一眼即知**：优先展示 AI 额度，兼顾系统状态。
- **轻量常驻**：采用 Swift + AppKit，减少后台采样与绘制开销。
- **怪兽陪伴**：延续 Monster 产品命名风格，探索以小怪兽及轻量动效表达状态。
- **如实展示**：明确区分有效、过期与不可用数据。

## 当前状态

已迁入 Codex Dock PoC 的源码、构建脚本、测试脚本、视觉基准和验证文档。PoC 的可执行文件仍命名为 `CodexDock`，历史测量记录保留原名。

异常查询与退出路径已验证，30 分钟测试未见持续累积。低资源占用仍是待完成的验收目标：性能对比需补足重复次数、修正计量口径，并排查关闭窗口后的内存突增。

初期聚焦 Codex 订阅额度；后续可探索更多 AI 工具的额度与状态。

## 目录

```text
monster-pulse/
├── README.md
├── docs/          # 产品定位、设计方案与验证记录
└── example/
    ├── README.md
    └── codex-dock/ # 可构建的原生 macOS PoC
```

## 文档与示例

- [文档入口](docs/README.md)
- [示例入口](example/README.md)

## 快速开始

需要 macOS 13+、Xcode Command Line Tools；读取真实额度另需支持 app-server 的 Codex CLI，并以 ChatGPT 订阅方式登录。

在项目根目录运行：

```sh
bash example/codex-dock/build.sh
example/codex-dock/.build/CodexDock.app/Contents/MacOS/CodexDock --self-test
open example/codex-dock/.build/CodexDock.app
```

完整运行、打包和测试说明见 [PoC README](example/codex-dock/README.md)。

## 后续重点

- 排查关闭详情窗口后的内存突增。
- 完成至少三轮性能对比，并纳入活动监视器辅助进程。
- 验证系统睡眠与唤醒，以及 Dock 图标视觉表现。
- 探索 Monster 角色视觉与低帧率状态动效，并测量真实运行开销。
