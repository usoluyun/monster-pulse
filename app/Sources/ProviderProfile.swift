import Foundation

/// 额度来源的四表面 Profile：Dock / 右键菜单 / 主窗 / 设置。
///
/// 领域层已有 `QuotaSource` 与快照；本类型只回答「当前来源该怎么呈现」，
/// 禁止再用 `isWallet` 或「有没有 remaining」反推来源（见 AGENTS 第 10 条）。
/// 不 import AppKit，便于 `--self-test` 在创建 NSApplication 之前断言。
enum ProviderProfile: String, CaseIterable {
    case codex
    case newAPI

    static func of(_ source: QuotaSource) -> ProviderProfile {
        switch source {
        case .codex: return .codex
        case .newAPI: return .newAPI
        }
    }

    var source: QuotaSource {
        switch self {
        case .codex: return .codex
        case .newAPI: return .newAPI
        }
    }

    var label: String { source.label }

    var capabilities: ProviderCapabilities {
        switch self {
        case .codex:
            return ProviderCapabilities(
                hasTimeWindow: true,
                hasWallet: false,
                showsQuotaPercentAlerts: true,
                showsResetLeadAlerts: true,
                showsWalletTierAlerts: false,
                offersFollowAppProxy: false)
        case .newAPI:
            return ProviderCapabilities(
                hasTimeWindow: false,
                hasWallet: true,
                showsQuotaPercentAlerts: false,
                showsResetLeadAlerts: false,
                showsWalletTierAlerts: true,
                offersFollowAppProxy: true)
        }
    }

    /// 主窗口刷新按钮。
    var refreshButtonTitle: String {
        switch self {
        case .codex: return "刷新额度"
        case .newAPI: return "刷新钱包"
        }
    }

    /// Dock 右键菜单刷新项（含「立即」）。
    var dockRefreshTitle: String {
        switch self {
        case .codex: return "立即刷新额度"
        case .newAPI: return "立即刷新钱包"
        }
    }

    /// Dock 是否画 Codex 外圈百分比环。
    var showsQuotaRing: Bool { capabilities.hasTimeWindow }

    /// Monster 是否走零钱罐形态。
    var usesPiggyMonster: Bool { capabilities.hasWallet }

    /// 设置「预警」区在总开关之下应出现的控件（顺序即显示顺序）。
    /// 总开关本身两来源都有，不列入此表。
    var settingsAlertControls: [SettingsAlertControl] {
        switch self {
        case .codex:
            return [.quotaThreshold, .resetLead, .failureStreak, .diskIO]
        case .newAPI:
            return [.walletTierNote, .failureStreak, .diskIO]
        }
    }

    /// 设置「网络」区标题下的代理提示（不含用户刚输入的规范化回显）。
    var proxyHint: String {
        switch self {
        case .codex:
            return "用于 Codex 查询和出口 IP 探测。留空时出口探测使用系统代理；不读取 shell 代理。"
        case .newAPI:
            return "用于出口 IP 探测；勾选下方选项后也可供 New API 请求使用。留空时出口探测使用系统代理；不读取 shell 代理。"
        }
    }

    /// New API「跟随应用代理」复选框文案。
    static let followAppProxyTitle = "New API 请求使用应用代理（默认直连）"
}

struct ProviderCapabilities: Equatable {
    /// 是否有 5h / 周一类可信时间窗（太阳、时间环、重置预警依赖它）。
    var hasTimeWindow: Bool
    /// 是否按钱包金额 / 富足度表达（零钱罐、金额大字）。
    var hasWallet: Bool
    /// 设置是否展示「剩余低于 N%」滑杆。
    var showsQuotaPercentAlerts: Bool
    /// 设置是否展示「重置前 N 分钟」滑杆。
    var showsResetLeadAlerts: Bool
    /// 是否按钱包档位预警（偏紧 / 见底）。
    var showsWalletTierAlerts: Bool
    /// 是否提供「跟随应用代理」选项（本轮仅 New API）。
    var offersFollowAppProxy: Bool
}

/// 设置预警区控件。纯枚举，供 Profile 与自检共用，避免 UI 与测试各写一份列表。
enum SettingsAlertControl: String, Equatable {
    case quotaThreshold
    case resetLead
    case failureStreak
    case diskIO
    /// 仅说明文案，无滑杆。
    case walletTierNote
}
