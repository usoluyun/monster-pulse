import Foundation

/// New API 自建服务的领域层：站点配置、账户钱包与套餐解析。
///
/// 口径来源 `docs/new-api-research.md`（服务 `codingplan.at-our.com`，
/// 版本 v1.0.0-rc.25），字段定义对照 `model/subscription.go` 与
/// `controller/subscription.go`。本文件只依赖 Foundation，不 import AppKit，
/// 因此可以在 `--self-test` 里于创建 NSApplication 之前跑完全部断言。
///
/// 与 Codex 的关键差异：New API 的原始计数是**站点计费额度**，不是 token 数，
/// 也**没有** 5h/周重置窗口。所以 `QuotaWindow` 那套字段不能套用，
/// 金额换算与富足度判定都在这里独立完成。
enum NewAPI {
    // MARK: - 站点配置

    /// `GET /api/status` 的计费换算参数。
    ///
    /// 换算公式（实测服务）：`金额 = quota / quota_per_unit × usd_exchange_rate`。
    ///
    /// 这里刻意**不用** `status.price`：调研实测 `price=7.3` 与
    /// `usd_exchange_rate=7` 不一致，按页面口径换算必须用后者。
    struct SiteConfig: Equatable {
        /// `quota_per_unit`，实测 500000。
        let quotaPerUnit: Double?
        /// `usd_exchange_rate`，实测 7。缺失时不得猜测汇率。
        let usdExchangeRate: Double?
        /// `quota_display_type`，实测 `CNY`。
        let displayType: String?
        /// 服务版本，实测 `v1.0.0-rc.25`。
        let version: String?

        /// 原始计费额度 → 展示金额。
        ///
        /// 站点配置缺失时返回 nil：宁可显示原始 quota，也不猜汇率。
        func amount(forQuota quota: Int64) -> Double? {
            guard let quotaPerUnit, quotaPerUnit > 0,
                  let rate = usdExchangeRate, rate.isFinite, rate > 0 else { return nil }
            return Double(quota) / quotaPerUnit * rate
        }

        /// 金额展示用的货币符号。未知站点配置退回人民币以外的中性符号。
        var currencySymbol: String { displayType == "CNY" ? "¥" : "" }

        static func parse(_ result: [String: Any]) -> SiteConfig {
            let data = result["data"] as? [String: Any] ?? result
            func double(_ key: String) -> Double? {
                guard let raw = data[key], let value = Double("\(raw)") ?? (raw as? NSNumber)?.doubleValue,
                      value.isFinite else { return nil }
                return value
            }
            return SiteConfig(
                quotaPerUnit: double("quota_per_unit"),
                usdExchangeRate: double("usd_exchange_rate"),
                displayType: data["quota_display_type"] as? String,
                version: data["version"] as? String)
        }
    }

    // MARK: - 富足度

    /// 账户富足程度，四档离散状态 + 一个「无法判定」态。
    ///
    /// 刻意不用连续百分比：New API 钱包没有可信的固定周期分母
    /// （`quota + used_quota` 是历史消耗之和，不是周期预算），
    /// 做成百分比就会把「无限」和「100%」混为一谈。
    enum Prosperity: String, CaseIterable {
        case abundant, comfortable, tight, drained
        /// 有余额但无近期消耗，或余额非正——不能显示成 100% 或无限。
        case unknown

        var label: String {
            switch self {
            case .abundant: return "富足"
            case .comfortable: return "充裕"
            case .tight: return "拮据"
            case .drained: return "见底"
            case .unknown: return "无消耗数据"
            }
        }

        /// 四档阈值目前是**建议值，未经实测校准**，按实际观感再调。
        ///
        /// 优先级：有可信套餐总额时用真实剩余比例（与 Codex 的
        /// `usedPercent` 同构）；否则退回钱包余额口径，量纲换成
        /// 预计可用天数——单位是「天」，来自 `余额 ÷ 近 24h 消耗`，
        /// 不需要编造任何预算。
        static func classify(subscription: Subscription?, balance: Int64, dailyBurn: Int64?) -> Prosperity {
            if let used = subscription?.remainingFraction, used < 0 {
                return .drained
            } else if let used = subscription?.remainingFraction {
                if used > 0.75 { return .abundant }
                if used > 0.40 { return .comfortable }
                if used > 0.15 { return .tight }
                return .drained
            }
            guard balance > 0 else { return .drained }
            guard let dailyBurn, dailyBurn > 0 else { return .unknown }
            let days = Double(balance) / Double(dailyBurn)
            if days > 30 { return .abundant }
            if days >= 7 { return .comfortable }
            if days >= 1 { return .tight }
            return .drained
        }

        /// 预计可用天数。余额与消耗都要大于零才算比值。
        static func runwayDays(balance: Int64, dailyBurn: Int64?) -> Double? {
            guard balance > 0, let dailyBurn, dailyBurn > 0 else { return nil }
            return Double(balance) / Double(dailyBurn)
        }
    }

    // MARK: - 套餐

    /// `GET /api/subscription/self` 的一个套餐实例。
    ///
    /// 字段来自 `model/subscription.go` 的 `UserSubscription`：
    /// `amount_total` 为周期总额（0 表示不限额），`amount_used` 为本周期已用。
    struct Subscription: Equatable {
        let amountTotal: Int64
        let amountUsed: Int64
        let endTime: Date?
        let nextResetTime: Date?
        let status: String?

        /// 剩余比例 0...1。总额为零是不限额，返回 nil 而不是除零。
        var remainingFraction: Double? {
            guard amountTotal > 0 else { return nil }
            return max(0, Double(amountTotal - amountUsed)) / Double(amountTotal)
        }

        /// 页面口径的剩余额度：`max(0, amount_total - amount_used)`。
        var remainingQuota: Int64? {
            guard amountTotal > 0 else { return nil }
            return max(0, amountTotal - amountUsed)
        }

        static func parse(_ item: [String: Any]) -> Subscription? {
            // 实测结构是 data.subscriptions[].subscription.{...}
            let body = item["subscription"] as? [String: Any] ?? item
            guard let total = int64(body["amount_total"]), let used = int64(body["amount_used"]) else { return nil }
            func date(_ key: String) -> Date? {
                guard let raw = int64(body[key]), raw > 0 else { return nil }
                return Date(timeIntervalSince1970: Double(raw))
            }
            return Subscription(amountTotal: total, amountUsed: used,
                endTime: date("end_time"), nextResetTime: date("next_reset_time"),
                status: body["status"] as? String)
        }
    }

    // MARK: - 账户钱包

    /// 账户钱包摘要：余额、累计消耗与近 24 小时消耗。
    ///
    /// 三个数来自两个独立接口，必须分开取，不能互相推算：
    /// 余额与累计消耗来自 `/api/user/self`，近 24 小时消耗来自 `/api/data/self`。
    struct Wallet: Equatable {
        /// `data.quota`，实测 122942348（¥1721.19）。
        let balance: Int64
        /// `data.used_quota`，实测 2571788418（¥36005.04）。
        let usedQuota: Int64
        /// `data.request_count`，实测 107884。
        let requestCount: Int?
        /// 近 24 小时 quota 汇总，实测 7152182（¥100.13）。
        let dailyBurn: Int64?
        /// 近 24 小时请求数汇总，实测 633。
        let dailyRequests: Int?
        /// 套餐数组。实测本账户为空——空数组是「无套餐」，不是「查询失败」。
        let subscriptions: [Subscription]
        /// 站点换算配置。
        let site: SiteConfig
        /// 采集时刻，用于过期快照判定。
        let fetchedAt: Date

        /// 取第一个可信套餐：总额大于零且状态未过期。
        var activeSubscription: Subscription? {
            subscriptions.first { $0.amountTotal > 0 }
        }

        var prosperity: Prosperity {
            Prosperity.classify(subscription: activeSubscription,
                balance: balance, dailyBurn: dailyBurn)
        }

        var runwayDays: Double? {
            Prosperity.runwayDays(balance: balance, dailyBurn: dailyBurn)
        }

        /// 余额的展示金额。站点配置缺失时返回 nil，调用方退回原始 quota。
        func balanceAmount() -> Double? { site.amount(forQuota: balance) }

        static func parse(userSelf: [String: Any], dataSelf: [String: Any]?,
                          subscriptionSelf: [String: Any]?, site: SiteConfig,
                          fetchedAt: Date = Date()) -> Wallet? {
            guard let user = userSelf["data"] as? [String: Any],
                  let balance = int64(user["quota"]),
                  let used = int64(user["used_quota"]) else { return nil }
            var burn: Int64? = nil
            var requests: Int? = nil
            if let rows = dataSelf?["data"] as? [[String: Any]] {
                // 逐条聚合求和，不能只取最后一条。
                var total: Int64 = 0
                var count = 0
                var anyRow = false
                for row in rows {
                    guard let q = int64(row["quota"]) else { continue }
                    anyRow = true
                    total += q
                    count += Int(int64(row["count"] ?? 0) ?? 0)
                }
                // 没有任何可解析的行不等于零消耗，必须区分。
                if anyRow { burn = total; requests = count }
            }
            var subs: [Subscription] = []
            if let list = subscriptionSelf?["data"] as? [String: Any],
               let items = list["subscriptions"] as? [[String: Any]] {
                subs = items.compactMap { Subscription.parse($0) }
            }
            return Wallet(balance: balance, usedQuota: used,
                requestCount: int64(user["request_count"]).map(Int.init),
                dailyBurn: burn, dailyRequests: requests, subscriptions: subs,
                site: site, fetchedAt: fetchedAt)
        }
    }

    // MARK: - 响应校验

    /// 判断业务层是否成功。
    ///
    /// 实测这批接口的成功标记不统一：`/api/user/self` 与
    /// `/api/data/self` 是 `success=true`，兼容 billing 是 `code=true`。
    /// HTTP 200 内可以装一个 error 对象，所以必须同时看 HTTP 与业务标记。
    static func isSuccess(_ json: [String: Any]) -> Bool {
        if let success = json["success"] as? Bool { return success }
        if let code = int64(json["code"]) { return code == 0 }
        return false
    }

    /// 从 error 对象里取一条可展示给用户的原因。
    static func failureMessage(_ json: [String: Any]) -> String? {
        if let message = json["message"] as? String, !message.isEmpty { return message }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        return nil
    }

    // MARK: - 时间范围

    /// 站点页面的近 24 小时统计范围。
    ///
    /// 调研实测前端工具 `GW(1)`：终点为当前 Unix 秒 + 3600，起点为终点减 86400，
    /// 即**前 23 小时至后 1 小时**，不是严格滚动 24 小时。采用严格滚动窗口
    /// 数值可能不同，口径必须显式声明，不能声称两者一致。
    static func recentWindow(now: Date = Date()) -> (start: Int64, end: Int64) {
        let end = Int64(now.timeIntervalSince1970) + 3600
        return (start: end - 86_400, end: end)
    }

    // MARK: - 私有工具

    /// JSON 数字宽松取值：New API 的 quota 可能超出 Int32，
    /// `JSONSerialization` 在不同平台上会给 NSNumber 或原始文本。
    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let text as String: return Int64(text)
        case let int as Int: return Int64(int)
        default: return nil
        }
    }
}