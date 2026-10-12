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

    /// 快照采集时刻。
    var fetchedAt: Date {
        switch self {
        case .codex(_, let fetchedAt): return fetchedAt
        case .newAPI(let wallet): return wallet.fetchedAt
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