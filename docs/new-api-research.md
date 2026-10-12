# M3 · New API 接入调研

调研日期：2026-10-10。服务：`https://codingplan.at-our.com/`。本轮为接口调研与接入方案，尚未修改应用实现。

## 结论

用户需要独立的「额度来源：Codex / New API」切换，并在设置里单独填写 New API 地址与 Token。用户随后提供正确的账户访问令牌，已实测取得钱包余额、账户累计消耗、最近 24 小时消耗，并可计算预计可用天数。M3 应以账户访问令牌接入钱包摘要。首轮提供的模型调用 API Key 只能查询该 Key 自身信息，不能代替账户凭据；其「不限额」与账户钱包余额是不同口径。

「令牌不限额」仅描述 Token 自身限制，不保证账户钱包或订阅永不耗尽。本轮全部为 GET 请求，未调用模型、充值或修改服务配置。凭据未保存到项目文件。

## 真实请求证据

请求带 `Authorization: Bearer <用户提供的 API Key>`；状态接口不需凭据。通过本机 curl 直连域名，保留 TLS 校验。下表为调研时快照。

| GET 路径 | HTTP | 结果与口径 |
| --- | --- | --- |
| `/api/status` | 200 | `version=v1.0.0-rc.25`，`quota_display_type=CNY`，`quota_per_unit=500000`，`usd_exchange_rate=7` |
| `/api/usage/token/` | 200 | `code=true`，`object=token_usage`，累计已用 `8586005`，剩余 `-8586005`，总额 `0`，`unlimited_quota=true`，`expires_at=0` |
| `/v1/dashboard/billing/subscription` | 200 | 三个 limit 字段均为 `100000000`，`access_until=0`；结合版本源码，这是无限 Token 的占位值，不是真实余额 |
| `/v1/dashboard/billing/usage` | 200 | `total_usage=12020.407`，与 Token 原始额度按站点换算后的金额 ×100 一致 |
| `/api/log/token` | 200 | `success=true`，返回 1000 条，JSON 约 862 KB；包含模型、计费 quota、输入输出 token、时间与计费来源字段 |
| `/api/user/self` | 401 | `AUTH_UNAUTHORIZED` / `Unauthorized, invalid access token` |
| `/api/subscription/self` | 401 | 同上，当前 API Key 不能读账户订阅 |

路径有尾斜杠差异：`/api/usage/token` 返回 301 到 `/api/usage/token/`；`/api/log/token/` 返回 301 到 `/api/log/token`。实现应使用最终路径，并禁止向其他 origin 的重定向携带凭据。

`model_limits` 是允许调用的模型名单，并非各模型用量。该 Token 开启模型限制。本轮实际日志模型为 `deepseek-v4-pro`（30 条）和 `glm-5.3-flash`（970 条）。返回记录覆盖 UTC 2026-09-22 12:26:41 至 2026-09-24 16:55:24，消费记录 quota 合计 `6018022`，小于累计 `8586005`。只能标为「返回的近期记录」，不能标为完整历史、今日或本周总量。

## 单位与协议陷阱

原始 quota 是服务计费额度，不能直接标成模型输入输出 token 数。按此站点配置：

```text
人民币金额 = quota / 500000 × 7
累计消耗 = 8586005 / 500000 × 7 = ¥120.20407
```

不能用状态接口的 `price=7.3` 代替 `usd_exchange_rate=7`。此版本兼容 billing 接口即使字段名带 `_usd`，数值仍按站点展示单位换算；`total_usage` 再乘 100。金额应以原始 quota 与站点状态配置计算，保留原始值与换算依据。状态配置缺失时显示原始计费额度，不能猜汇率。

处理 `unlimited_quota` 要早于余额与比例校验：本实例无限 Token 的 `total_available` 为负、`total_granted` 为零，这不表示欠费，也不能除以零。`expires_at=0` 表示 Token 无到期时间，不是周期重置；接口没有提供 Codex 那样的 5 小时或周窗口。

用量接口成功标记是 `code=true`；日志接口是 `success=true`。需要同时检查 HTTP、业务成功标记、对象类型和字段，不把 HTTP 200 内的 error 对象当成功。billing 接口统计范围受服务端 `DisplayTokenStatEnabled` 控制；本次返回值与 Token 消耗吻合，但通用客户端不应据此默认所有实例都是 Token 范围。

## 建议接入方案

### 配置与切换

- 新增「额度来源」选择：Codex / New API，与现有「仪表 / Monster」视图选择独立。
- New API 地址、Token 独立配置；地址保存到配置，Token 使用 macOS Keychain 与安全文本输入，不写 UserDefaults、日志或截图。
- 提供「检查连接」，显示服务版本、统计范围、单位、令牌是否限额及可取得的数据。API Key 与账户访问凭据要明确区分。
- 此域名直连已验证。New API 网络策略应能独立选择直连或代理，不能直接继承 Codex 的应用代理而忽略公司域名绕过要求。GUI 网络行为尚未验证。

### 领域与查询

现有 `QuotaWindow` / `Quota` 表达百分比和时间窗口。新增不 import AppKit 的 New API 领域解析与查询文件，并引入来源快照，分别保存 Codex 窗口和 New API 原始额度、无限标记、单位、采集时间及可选模型记录。不能把金额塞进 `usedPercent`，也不能造 300 / 10080 分钟窗口。

常规刷新只读取状态配置及 Token 用量，模型日志按需读取，避免每次刷新传输近 1 MB。此版本 `GetLogByTokenId` 仅取 `MaxRecentItems` 条，不提供分页与时间过滤参数；日志不足以实现完整的周期汇总。缓存按服务地址与凭据身份隔离。切换来源时清除当前显示与预警基线，取消或丢弃旧请求结果，避免晚返回的 Codex 数据覆盖 New API。

### 界面与预警

Codex 模式继续显示 5h / 周额度与重置时间。New API 模式显示明确的来源、令牌累计消耗、令牌剩余额度或「不限额」、更新时间；当前凭据下账户余额标为不可用。

有限 Token 且总额度有效时，可用剩余 / 总额驱动角色填充或 Dock 比例，并明确它是 Token 当前额度比例。不限额用独立的无限状态，不能伪装成 100%。New API 没有周窗口和重置时间，应移除相应太阳额度映射与时间环；最终视觉方案尚未确认。不限额不触发低百分比预警，查询失败和旧快照仍可独立处理。

### 账户余额的边界

如果目标包含真实账户钱包余额或订阅周期限额，需要增加账户凭据流程或由自建服务提供专用只读接口。当前 API Key 对相关接口实测为 401；本轮未取得账户访问凭据，未验证那套凭据的请求头、权限与套餐数据。Token 不限额无法推算钱包余额。

## 验证范围

已验证：真实服务状态、当前 API Key 认证、Token 用量、兼容 billing、近期日志、账户与订阅接口拒绝当前凭据、路径重定向。沙箱内 DNS 失败，授权后沙箱外直连成功；Python 默认本地 CA 库验证失败，改用 curl 正常验证 TLS，未关闭证书校验。

尚未验证：原生 URLSession、Keychain、Dock/Finder 启动网络、GUI 来源切换、有限 Token、失效或耗尽 Token、账户凭据、周期套餐额度及 GUI 数值对照。实施后需分别验收这些能力，不能以本轮终端请求代替应用验收。

## 第二轮：追踪实际页面数据（2026-10-10）

用户指出钱包相关界面有剩余额度、总量、可用时长与 24 小时消耗。进一步读取部署站点的公开前端资源，确认这些数据的接口与计算方式。第一轮「当前 API Key 无权读账户」仍成立，但不能将它表述为「New API 没有账户额度或周期统计接口」。

### 页面字段映射

| 页面数据 | 来源 | 口径 |
| --- | --- | --- |
| 剩余额度 / 当前余额 | `GET /api/user/self` → `data.quota` | 账户余额，独立于 API Key 自身限额 |
| 累计消耗 / Total Usage | 同接口 → `data.used_quota` | 账户累计计费消耗，不能等同单个 API Key 的累计消耗 |
| 账户额度总量（若要定义） | `quota + used_quota` 可作当前余额与历史消耗之和 | 实际前端未把此和显示成套餐总额；不能当成固定周期预算或充值总额 |
| 套餐总额 / 已用 / 剩余 | `GET /api/subscription/self` → `data.subscriptions[].subscription.amount_total / amount_used` | 页面剩余为 `max(0, amount_total - amount_used)`；总额为零按不限额处理 |
| 24 小时消耗 / Last 24h usage | `GET /api/data/self?start_timestamp=…&end_timestamp=…&default_time=hour` → `data[].quota` 求和 | 账户时间范围统计，独立于仅取近期 1000 条的日志接口 |
| 可用时长 / Runway | 前端计算 `账户余额 / 上述时间范围消耗` | 单位为估算天数；不是 API 直接返回，不是套餐有效期 |
| 套餐到期与下次重置 | `GET /api/subscription/self` → `end_time / next_reset_time` | 独立于 Runway；接口实际账户数据尚未取得 |

实际 `/wallet/` 页面代码包含账户余额、累计消耗、请求数及套餐额度；Runway 与 Last 24h usage 位于统计总览的钱包摘要卡，可跳转钱包。无论用户如何称呼该区域，四项数据来源已定位。

Runway 的实际代码：余额与消耗都大于零才算比值；小于一天显示「不足 1 天」，大于 999 天显示「999+ 天」，否则向下取整并加约数标记。余额非正显示「余额耗尽」，有余额但没有近期消耗显示「无近期用量」，不能显示无限天。

前端的时间工具 `GW(1)` 默认终点为 `当前 Unix 秒 + 3600`，起点为终点减 86400，即查询范围约为当前前 23 小时至后 1 小时。总览再按返回的小时聚合数据求和，标签叫「24 小时」。客户端若要与页面严格一致，需要采用同一范围；若采用严格滚动最近 24 小时，应明确统计口径差异，不能声称数值必定一致。聚合桶边界与真实账户数据尚未对照。

### 第二轮真实请求

当前 API Key 复查累计 quota 仍为 `8586005`，无限标记仍为 true。

| 请求 | 实测结果 |
| --- | --- |
| `/api/user/self`、`/api/subscription/self` | 均 401 / `AUTH_UNAUTHORIZED` |
| `/api/data/self`、`/api/log/self/stat?type=2` | 均 401 / `AUTH_UNAUTHORIZED` |
| `/dashboard/billing/subscription` | 200，与带 `/v1` 别名一样返回无限 Token 占位值 |
| 两个 billing usage 路径加 `start_date=2026-10-10&end_date=2026-10-10` | 均仍返回累计 `12020.407`；不能用日期参数取得今日消耗 |
| `/api/log/token?page=2&page_size=1&start_timestamp=1791580800` | 仍返回同一范围的 1000 条，quota 合计仍为 `6018022`；分页和日期参数未生效 |
| `/dashboard/billing/credit_grants` | HTTP 200，但返回 HTML 入口页，不是额度 JSON 接口 |
| `/api/usage/token/` 不带凭据 | 401 / `Token not provided` |
| `/api/usage/token/` 带专门构造的无效凭据 | 401 / `Invalid token` |

### 鉴权与实现方向修订

对应版本 `middleware/auth.go` 的 `UserAuth` 接受控制台登录访问令牌或账户 PAT（个人访问令牌），通过 `Authorization` 鉴权；它与模型调用 API Key 是两套凭据。当前 API Key 无法通过账户鉴权。本轮未取得账户 PAT，因此这些接口字段由部署前端与对应版本源码确认，真实余额与 24 小时消费值尚未验证。

此版本有 `GET /api/user/token` 生成账户访问令牌，但 `GenerateAccessToken` 会写入并替换账户令牌，不能因方法是 GET 就当成只读接口。本轮没有调用它。

若 M3 要复现账户钱包摘要，应支持「New API 账户访问令牌」配置，用 `/api/user/self` 加 `/api/data/self` 获取余额与近期消耗，再计算 Runway；套餐数据通过 `/api/subscription/self` 单独获取。模型调用 API Key 可保留为可选配置，用于查看该 Key 的独立消耗；不能用 Key 的不限额标记覆盖账户余额。账户余额没有固定周期分母，建议显示金额和预计可用天数；套餐有可信总额时才适合显示剩余比例。

需取得账户访问令牌后再真实核对四项数值。账户 PAT 的权限范围不能假设为只读；应用仅执行查询请求，凭据仍需 Keychain 存储。未从浏览器提取登录凭据或生成新凭据。

### 本轮依据

- 部署前端入口：`/static/js/index.172656cc78.js`，包含账户查询与资源映射。
- 钱包页面：`/static/js/async/2029.a169f55b0a.js`，包含 `/api/subscription/self`、余额及累计消耗展示。
- 统计总览：`/static/js/async/230.374b1e1a43.js`，包含 `/api/data/self`、quota 汇总与 Runway 公式。
- 时间工具：`/static/js/async/1402.b5514f8c6b.js`，包含 `GW` 查询时间范围。
- [账户鉴权实现](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.25/middleware/auth.go)：账户 PAT 与模型调用 Key 的认证区别；只读 Token 鉴权的顶部注释与实际禁用状态分支不一致，须以代码分支为准，耗尽/过期/禁用行为尚未实测。
- [账户字段和令牌生成](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.25/controller/user.go)：余额、累计消耗及令牌生成副作用。
- [套餐数据结构](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.25/model/subscription.go)：额度、到期与重置时间。

## 第三轮：正确账户令牌实测（2026-10-10）

用户补充账户访问令牌后，以 `Authorization: Bearer <账户访问令牌>` 直连原服务，只读查询成功。以下快照查询时间为北京时间 2026-10-10 13:28:18；没有将凭据写入项目文件。

| 数据 | 实测原始值 | 按站点配置换算 / 解释 |
| --- | --- | --- |
| 账户余额 `quota` | `122942348` | ¥1,721.192872，展示 ¥1,721.19 |
| 账户累计消耗 `used_quota` | `2571788418` | ¥36,005.037852，展示 ¥36,005.04 |
| 账户请求数 `request_count` | `107884` | 账户累计请求数 |
| 最近 24 小时 quota 汇总 | `7152182` | ¥100.130548，展示 ¥100.13 |
| 最近 24 小时请求数汇总 | `633` | 8 条聚合记录中 `count` 之和 |
| 预计可用天数 | `122942348 / 7152182` | 17.189488 天；页面向下取整显示约 17 天 |
| 余额 + 历史消耗 | `2694730766` | ¥37,726.230724；非周期预算、非已验证充值总额 |

`GET /api/user/self` 返回 HTTP 200 / `success=true`。`GET /api/subscription/self` 同样成功，`subscriptions=[]`、`all_subscriptions=[]`，`billing_preference=subscription_first`。当前账户没有返回任何套餐，显示钱包余额即可，不能虚构套餐总额度或重置时间。

近期数据接口实测：

```text
GET /api/data/self?start_timestamp=1791527298&end_timestamp=1791613698&default_time=hour
```

上述范围采用部署页面算法（现在前 23 小时至后 1 小时），返回 HTTP 200 / `success=true`、8 条聚合记录。另查严格滚动 24 小时范围 `1791523698...1791610098`，本次返回相同 8 条与相同汇总值。两种范围本次一致，不能据此认为以后永远一致。

站点状态也重新读取，仍为 CNY、`quota_per_unit=500000`、`usd_exchange_rate=7`，上述金额按 `quota / 500000 × 7` 换算。预计天数使用原始 quota 比值，避免金额四舍五入影响结果。

### M3 可实施范围

设置新增「额度来源：Codex / New API」及独立 New API 地址、账户访问令牌。用户此前更正了凭据类型，因此钱包接入只需此账户令牌；模型调用 API Key 不作为必填字段。

New API 模式可展示账户余额、累计消耗、最近 24 小时消耗、预计可用天数与更新时间；套餐查询成功但为空时明确无套餐。当前钱包没有可信的固定周期分母，Dock / Monster 映射需针对金额与预计天数设计，不能将历史消耗之和当成周期总额。Codex 模式继续采用真实 5h / 周窗口。

原生网络、Keychain、GUI 切换与实际页面数字对照仍未验证。本轮已独立证明账户接口可用，不再以 API Key 的 401 作为账户接入障碍。

## 第一轮对应版本参考

- [令牌用量实现](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.25/controller/token.go)：`GetTokenUsage`，原始额度、无限标记、秒级到期时间。
- [兼容计费实现](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.25/controller/billing.go)：站点展示单位换算、统计范围、无限额度占位值。
- [路由与认证](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.25/router/api-router.go)：Token 只读认证与账户认证分开。
- [日志查询实现](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.25/model/log.go)：`GetLogByTokenId` 的记录上限。
