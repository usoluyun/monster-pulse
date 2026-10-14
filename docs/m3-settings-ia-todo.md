# M3 · Provider Profile 与 CI 验收待办

记录日期：2026-10-14。状态：**验收通过**（D1 CI 绿 + D2 Dock/Finder 点验完成，2026-10-14）。

## 决策（已拍板）

1. **架构选 B**：每个额度来源一套 Provider Profile，覆盖 Dock 图标、右键菜单、主窗口、设置页四块表现；共用系统指标 / 开机自启 / 仪表·Monster 总开关。为 M4（Zen / Go）预留扩展点，禁止再用 `isWallet` 或「有没有 remaining」反推来源。
2. **M3 必须补可进 CI 的单元测试**：以现有 `--self-test` 为载体；由 GitHub Actions 在推送 / PR 上触发。
3. **CI 绿 ≠ 验收完成**：Actions 通过后，由本对话 Agent 按清单做二次验收（含必须从 Dock / Finder 启动的项）。

已拍板（2026-10-14）：

1. **New API 网络**：本轮「直连 + 可选跟随应用代理」够用；独立代理二期。
2. **未选中来源凭据**：本轮**只配当前来源**（切换来源时整段替换当前来源区；不可用配置不可见）。M4 再考虑「配置此来源…」二级窗常驻多来源凭据。

---

## 目标形态（B）

见 `app/Sources/ProviderProfile.swift`：`ProviderProfile` + `ProviderCapabilities` + `SettingsAlertControl`。

| 区 | 内容 |
| --- | --- |
| 共用 | 系统刷新间隔、四项系统显示、Monster 外观、开机自启 |
| 当前来源 | 凭据 + 该来源预警 + 该来源额度刷新语义 |
| 网络 | Codex：应用代理；New API：直连 / 跟随应用代理（无独立代理字段） |
| 凭据可见性 | 只展示当前来源的凭据与专属项；切走即整段移除 |

Profile 轮刻意不做、已另开分支完成：零钱罐视觉重做 + New API 仪表读数卡（`m3-wallet-visual`）。仍不做：接 M4、合并两套额度为单一百分比、令牌迁回 UserDefaults。

---

## 阶段 0 · CI 基线

- [x] 新增 `.github/workflows/ci.yml`：`push` / `pull_request` 触发，`runs-on: macos-15`
- [x] 步骤：`bash app/build.sh` → `--self-test`
- [x] 本轮不把 `render-regress` 放进默认 CI
- [x] README / `docs/poc-usage.md` 已说明
- [x] 用一次推送 / PR 确认 Actions 真绿（PR #1）

---

## 阶段 A · Profile 定稿

- [x] `capabilities` 表（时间窗、钱包、预警项、跟随代理）
- [x] 四表面 Presenter 收敛到 Profile 字段 + `QuotaSummary.source`
- [x] 分区硬规则写入本文与代码注释
- [x] `--self-test` 断言清单（见阶段 T）

---

## 阶段 B · 实现 Profile + 消灭串台

- [x] 引入 `ProviderProfile`；Codex / NewAPI 两份能力
- [x] 删除 `QuotaSummary.isWallet`（改 `source` + `usesWalletChrome`）
- [x] 设置：按来源重建预警行；New API 无「重置前 / 剩余%」
- [x] New API「跟随应用代理」可配置（默认直连）
- [x] 代理区改标题「网络」，提示随 Profile
- [x] Dock / 菜单 / 主窗刷新文案走 Profile；无快照用 `activeSource`
- [x] 同步 settings 基线并看图；`render-regress` 93 PASS
- [x] Keychain 无 UI 交互（`LAContext.interactionNotAllowed`），避免自检挂死

---

## 阶段 T · M3 单元测试（进 `--self-test`）

- [x] Profile 身份与能力
- [x] Presenter / 摘要文案隔离
- [x] 刷新标题（按钮 + Dock）
- [x] 设置预警控件集合按来源
- [x] 跟随应用代理默认直连 / 勾选生效
- [x] Dock 菜单两来源刷新文案；无快照时 New API 仍用钱包文案
- [x] 故障注入：New API 预警集合含 `quotaThreshold` → 自检红 → 已恢复
- [x] 本地 `--self-test` + `render-regress` 通过

---

## 阶段 C · 文档与边角

- [x] `roadmap.md` / docs README 指向本待办与 ci.yml
- [x] README / roadmap 的 M3 状态与实现一致（见下）
- [x] 详情 / Dock / 设置刷新文案统一走 Profile

---

## 阶段 D · 验收门禁（两道，缺一不可）

### D1 · GitHub Actions（自动）

- [x] PR / 推送上 `ci.yml` 全绿（PR #1，commit `0eb8e32`）
- [x] Agent `subscribe_github_ci` 已收到 success
- [x] CI 绿，进入 D2

### D2 · Agent 人工场景验收（CI 绿之后）

- [x] 本机 `--self-test` 与 CI 一致再跑一遍 PASS
- [x] 本机 `render-regress`（含 newapi / wallet）已绿并看过设置图
- [x] **从 Dock / Finder 启动**：Codex + 应用代理可刷新额度（用户 2026-10-14 点验）
- [x] **从 Dock / Finder 启动**：New API 直连「检查连接」与真实页面金额对照（同上）
- [x] 来源切换不串台（同上）
- [x] 右键菜单 / 主窗刷新文案随来源正确（同上）
- [x] roadmap M3 状态已更新

---

## Agent 工作流

```text
改代码 → 本地 --self-test → 推 PR
      → subscribe_github_ci(head branch)
      →（等待 CI 通知）
      → 绿：跑 D2 清单 → 汇总给用户
      → 红：修 → 再推 → 再订阅
```
