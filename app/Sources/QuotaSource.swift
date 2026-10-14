import Foundation

/// 额度来源。M3 引入的抽象层：Codex 与 New API 的数据口径完全不同，
/// 不能塞进同一个 `Quota`——New API 没有 5h/周窗口，把金额硬塞进
/// `usedPercent` 等于伪造一个不存在的分母。
///
/// 本文件只负责「来源身份」与「结果时效」，不负责取数（取数在
/// Metrics.swift 的 CodexReader 与 NewAPI.swift 的解析层）。
enum QuotaSource: String, CaseIterable {
    case codex
    case newAPI

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .newAPI: return "New API"
        }
    }

    /// 该来源是否提供可用的时间窗口。New API 没有可信周期分母，
    /// 不能映射成太阳高度或时间环——那是 Codex 独有的表达。
    var hasTimeWindow: Bool { self == .codex }
}

/// 请求世代。切换来源或重新发起刷新都会推进世代。
///
/// 存在的理由：`refresh()` 用 `guard !loading` 保证同时只有一个在途请求，
/// 但**切来源时那个请求不会被取消**。若不比对世代，切到 New API 之后，
/// 晚返回的 Codex 结果会覆盖新来源的显示——而且是偶发的，
/// 只在 Codex 查询比 New API 慢时才出现，极难复现。
struct QuotaEpoch: Equatable {
    private let generation: Int

    static let initial = QuotaEpoch(generation: 0)

    /// 推进一代。切换来源、手动刷新、睡眠唤醒都应调用。
    func advanced() -> QuotaEpoch { QuotaEpoch(generation: generation + 1) }

    /// 结果回来时判断是否仍然有效。
    /// - Parameter issued: 请求发起时记下的世代。
    func accepts(_ issued: QuotaEpoch) -> Bool { issued.generation == generation }
}

/// 缓存隔离键：服务地址 + 凭据指纹。
///
/// 换服务或换凭据后，旧缓存必须整体失效，否则会显示另一个账户的钱包余额。
/// 凭据只取指纹不取原文——令牌明文不该出现在缓存键这种会被打印、
/// 会进日志、会留在内存转储的地方。
struct QuotaCacheKey: Hashable {
    let baseURL: String
    let credentialFingerprint: String

    init(baseURL: String, accessToken: String) {
        self.baseURL = baseURL
        self.credentialFingerprint = QuotaCacheKey.fingerprint(accessToken)
    }

    /// FNV-1a 64 位。用途是区分凭据而不是防攻击，不需要密码学强度。
    private static func fingerprint(_ token: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in token.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 36)
    }
}

/// 来源无关的额度摘要。
///
/// Dock 图标大字、主窗口读数、详情窗口与右键菜单四处都要展示额度，
/// 但两个来源能提供的东西完全不同：Codex 有百分比和两个时间窗口，
/// New API 只有金额和富足度四档。把这四种展示收敛到一处，
/// 免得每处各写一遍 if、其中一处漏改就在某个界面露出 Codex 的残留。
struct QuotaSummary {
    /// Dock 图标中央的大字。Codex 是剩余百分比数字，New API 是金额。
    /// 为 nil 表示这一侧没有可展示的数字（例如 Codex 快照里没有窗口）。
    /// 「%」不在这里：它与外圈同属百分比通道，视图靠「大字是否为 nil」判断来源。
    let bigNumber: String?
    /// 详情窗口与右键菜单逐行文案。
    let detailLines: [String]
    /// 显式来源。无快照时为 nil——不得用文案或字段有无反推。
    let source: QuotaSource?
    /// 是否有任何可展示的数据。**不能**用 `quota != nil` 判断——
    /// New API 模式下 quota 恒为 nil，那样会把有数据判成「暂无数据」。
    let hasData: Bool
    /// New API 累计剩余份额 `余额/(余额+累计已用)`。Codex / 无数据为 nil。
    /// 仪表 Dock 画双色条用；**不是**周期进度。
    let walletRemainingShare: Double?

    var sourceLabel: String { source?.label ?? "" }
    var profile: ProviderProfile? { source.map(ProviderProfile.of) }

    /// 是否走钱包展示通道。由显式 `source` 决定，不用标签字符串比对。
    var usesWalletChrome: Bool { profile?.capabilities.hasWallet == true }

    /// 状态尾注。顺序与详情窗口一致：错误 > 过期。
    ///
    /// 有快照时**也要**带上 errorText：刷新失败但旧快照还在时，
    /// 只说「旧数据」而不说「刚才查询失败」，用户会以为是自然过期。
    /// 原实现直接丢弃 errorText，两处界面对同一次失败给出不同说法。
    /// 没有快照时不说「旧数据」——根本没有旧数据。
    private static func footer(errorText: String?, stale: Bool) -> [String] {
        var lines: [String] = []
        if let errorText { lines.append(errorText) }
        if stale { lines.append("旧数据，仅供参考") }
        return lines
    }

    static let empty = QuotaSummary(bigNumber: nil, detailLines: [],
                                    source: nil, hasData: false,
                                    walletRemainingShare: nil)

    static func of(_ snapshot: QuotaSnapshot?, loading: Bool = false,
                   errorText: String? = nil, stale: Bool = false,
                   now: Date = Date()) -> QuotaSummary {
        guard let snapshot else {
            var lines = [loading ? "正在查询…" : "暂无数据"]
            if let errorText { lines.append(errorText) }
            return QuotaSummary(bigNumber: nil, detailLines: lines,
                                source: nil, hasData: false,
                                walletRemainingShare: nil)
        }
        switch snapshot {
        case .codex(let quota, _):
            guard let window = quota.windows.first else { return .empty }
            var lines = ["\(QuotaFormat.windowTitle(minutes: window.minutes))　剩余 \(window.remaining)%"]
            if let reset = window.resetsAt.map({ QuotaFormat.countdown(to: $0, now: now) }) {
                lines.append("　重置 \(reset)")
            }
            lines.append(contentsOf: footer(errorText: errorText, stale: stale))
            return QuotaSummary(bigNumber: String(window.remaining),
                                detailLines: lines, source: .codex,
                                hasData: !quota.windows.isEmpty,
                                walletRemainingShare: nil)
        case .newAPI(let wallet):
            let symbol = wallet.site.currencySymbol
            func money(_ quota: Int64) -> String {
                wallet.site.amount(forQuota: quota)
                    .map { "\(symbol)\(String(format: "%.2f", $0))" } ?? "原始额度 \(quota)"
            }
            let share = wallet.lifetimeRemainingShare
            var lines = ["账户余额　\(money(wallet.balance))　\(wallet.prosperity.label)"]
            lines.append("近 24 小时消耗　\(money(wallet.dailyBurn ?? 0))")
            // 预计可用天数是余额÷近 24h 消耗，单日抖动大，必须标注为估算。
            if let days = wallet.runwayDays {
                lines.append(String(format: "预计可用　%.1f 天（按近 24h 消耗估算）", days))
            } else if wallet.balance > 0 {
                // 没有消耗数据不等于无限，明确说「无近期用量」
                lines.append("预计可用　无近期用量")
            }
            if let share {
                // 累计口径：余额/(余额+累计已用)，不是周期预算。
                lines.append(String(format: "累计剩余　%.0f%%（余额/(余额+累计已用)）", share * 100))
            }
            if let subscription = wallet.activeSubscription {
                lines.append("套餐剩余　\(String(format: "%.0f%%", (subscription.remainingFraction ?? 0) * 100))")
            }
            lines.append(contentsOf: footer(errorText: errorText, stale: stale))
            // Dock 大字：千分位金额更专业；档位由零钱罐与次行文案表达。
            let big = wallet.site.amount(forQuota: wallet.balance).map { amount -> String in
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 0
                let digits = formatter.string(from: NSNumber(value: amount.rounded())) ?? String(format: "%.0f", amount)
                return "\(symbol)\(digits)"
            }
            return QuotaSummary(bigNumber: big, detailLines: lines,
                                source: .newAPI, hasData: true,
                                walletRemainingShare: share)
        }
    }

    /// 仪表 Dock 次行：富足度 + 预计可用（仅钱包来源）。
    static func dockCaption(for snapshot: QuotaSnapshot?) -> String? {
        guard case .newAPI(let wallet) = snapshot else { return nil }
        var parts = [wallet.prosperity.label]
        if let days = wallet.runwayDays {
            parts.append(String(format: "约 %.0f 天", days.rounded()))
        } else if wallet.balance > 0, wallet.prosperity != .unknown {
            parts.append("无近期用量")
        }
        return parts.joined(separator: " · ")
    }
}

/// 来源快照的统一外壳。
///
/// 两个来源的载荷类型不同，这里只统一「采集时刻」这一项——
/// 过期判定与陈旧提示需要一个与来源无关的时间戳。
enum QuotaSnapshot {
    /// Codex 快照没有自带时间戳（`Quota.parse` 只认响应里的窗口），
    /// 所以采集时刻由写入方提供。
    case codex(Quota, fetchedAt: Date)
    case newAPI(NewAPI.Wallet)

    var source: QuotaSource {
        switch self {
        case .codex: return .codex
        case .newAPI: return .newAPI
        }
    }

    /// 采集时刻。
    var fetchedAt: Date {
        switch self {
        case .codex(_, let fetchedAt): return fetchedAt
        case .newAPI(let wallet): return wallet.fetchedAt
        }
    }

    /// Codex 窗口数据。New API 时为 nil——界面据此不画太阳高度与时间环，
    /// 因为它没有可信的周期分母，画出来等于伪造。
    var codexQuota: Quota? {
        switch self {
        case .codex(let quota, _): return quota
        case .newAPI: return nil
        }
    }

    /// New API 钱包。Codex 时为 nil。
    var newAPIWallet: NewAPI.Wallet? {
        switch self {
        case .codex: return nil
        case .newAPI(let wallet): return wallet
        }
    }

    /// 快照是否已过期。
    ///
    /// 阈值按来源分开：Codex 的 5h/周窗口按 15 分钟算陈旧就足以提醒用户
    /// 数据偏旧；New API 的余额是连续累计值，1 小时仍算合理，
    /// 用同一个阈值会让它在正常轮询下频繁报陈旧。
    func isStale(now: Date = Date()) -> Bool {
        let limit: TimeInterval = source == .codex ? 15 * 60 : 60 * 60
        return now.timeIntervalSince(fetchedAt) > limit
    }
}