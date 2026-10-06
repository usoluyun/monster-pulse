import Foundation

/// 额度预警。
///
/// 为什么用 Dock 图标跳动而不是系统横幅通知（实测结论，2026-10-06）：
/// · `UNUserNotificationCenter.requestAuthorization` 在 ad-hoc 签名的 .app 下
///   恒定返回 `granted=false` + `UNErrorDomain Code=1 "Notifications are not
///   allowed for this application"`，且 `lsregister -f` 也不能改变结果。
///   多个来源确认这需要有效的 Developer ID 签名（付费账号），本机无有效签名身份。
/// · 无 bundle 时 `UNUserNotificationCenter.current()` 抛 ObjC 异常
///   `bundleProxyForCurrentProcess is nil`，Swift 的 `catch` 接不住，
///   意味着 `--standalone` 产物一旦碰通知就会崩溃。
/// · `NSApplication.requestUserAttention(_:)` 在 ad-hoc 签名 .app 内实测返回
///   0（成功），不需要任何通知授权，也不受签名限制。对一个 Dock 常驻应用来说，
///   图标跳动本身就是最贴近的提醒面。
///
/// 预警只在**状态跃迁**时触发一次（跨入阈值 / 条件消失后可再次触发），
/// 不是每次轮询都提醒——否则 120 秒一次的轮询会把图标打成一直跳。
enum AlertMonitor {
    struct Window {
        let minutes: Int?
        let remaining: Int
        let resetsAt: Date?
    }

    /// 一次跃迁产生的预警。
    struct Alert {
        let key: String
        let title: String
        let body: String
    }

    /// 判断当前应处于「活跃」的预警集合。所有实现细节（去重、跃迁检测）
    /// 都在这里，便于脱离 AppKit 测试。
    static func activeAlerts(windows: [Window], failureStreak: Int, diskReadMBs: Double?,
                              config: Config, now: Date = Date()) -> Set<String> {
        guard config.alertsEnabled else { return [] }
        var active = Set<String>()

        // 额度阀值只看第一个有效窗口（Dock 图标显示的就是它）。
        // 多窗口都判一遍会让每周窗口在正常使用时也报警，噪音太大。
        // 阈值向上取整后比较：用户设「剩余低于 20%」时，剩余 20% 不算越线。
        if let first = windows.first,
           first.remaining < Int(config.alertQuotaThreshold.rounded(.up)) {
            active.insert("low-quota")
        }

        // 重置临近：对每个窗口各自判断，key 带窗口序号以便恢复
        for (index, window) in windows.enumerated() {
            guard let resetsAt = window.resetsAt else { continue }
            let lead = Double(config.alertResetLeadMinutes) * 60
            if resetsAt.timeIntervalSince(now) <= lead { active.insert("reset-soon-\(index)") }
        }

        if Double(failureStreak) >= config.alertFailureStreak { active.insert("query-failed") }

        // 磁盘读入速率。加载本地模型权重时这是主导开销——把 12GB 权重读进来
        // 会让机器发烫而 CPU 占用并不高，因为热源是统一内存带宽与 SSD，
        // 两者在 Apple Silicon 上同封装。只看内存占比看不到这件事。
        if let mbs = diskReadMBs, mbs >= config.diskAlertMBs { active.insert("disk-io") }
        return active
    }

    /// 为新进入 active 的条目生成文案。
    static func message(for key: String, windows: [Window], failureStreak: Int,
                        diskReadMBs: Double? = nil, config: Config, now: Date = Date()) -> Alert {
        switch key {
        case "low-quota":
            let remaining = windows.first?.remaining ?? 0
            return Alert(key: key, title: "额度偏低",
                         body: "主额度窗口剩余 \(remaining)%，已低于设定阈值 \(config.alertQuotaThreshold)%")
        case "query-failed":
            return Alert(key: key, title: "额度查询连续失败",
                         body: "已连续 \(failureStreak) 次无法获取额度，请检查 CLI 登录状态与网络")
        case "disk-io":
            let shown = SystemFormat.rate((diskReadMBs ?? 0) * 1_048_576)
            return Alert(key: key, title: "磁盘读取速率高",
                         body: "当前从磁盘读入 \(shown)，超过设定阈值 \(Int(config.diskAlertMBs)) MB/s。"
                             + "加载本地模型权重时属正常，机器发烫但 CPU 不高通常源于此")
        default:
            if key.hasPrefix("reset-soon-"),
               let index = Int(key.dropFirst("reset-soon-".count)),
               index < windows.count, let resetsAt = windows[index].resetsAt {
                return Alert(key: key, title: "额度即将重置",
                             body: "\(QuotaFormat.windowTitle(minutes: windows[index].minutes))将在 "
                                + QuotaFormat.countdown(to: resetsAt, now: now) + "重置")
            }
            return Alert(key: key, title: "额度提醒", body: "")
        }
    }

    /// 有状态的跃迁检测器。AppDelegate 持有一个实例，每次拿到新数据调
    /// `update(...)`，返回本次「新触发」的预警。
    ///
    /// 去重语义：条件成立时记入 active，条件消失时移除。再次成立才算新跃迁。
    /// 这样「持续低于阈值」只提醒一次，而不是每 120 秒提醒一次。
    final class Tracker {
        private var active = Set<String>()

        func update(windows: [Window], failureStreak: Int, diskReadMBs: Double?, config: Config,
                    now: Date = Date()) -> [Alert] {
            let current = AlertMonitor.activeAlerts(windows: windows, failureStreak: failureStreak,
                                                    diskReadMBs: diskReadMBs, config: config, now: now)
            // 先算文案再替换状态：message() 依赖的是本次数据
            let fresh = current.subtracting(active)
            let alerts = fresh
                .sorted()   // 固定顺序，便于测试断言
                .map { AlertMonitor.message(for: $0, windows: windows, failureStreak: failureStreak,
                                            diskReadMBs: diskReadMBs, config: config, now: now) }
            active = current
            return alerts
        }

        /// 把「当前成立的条件」记为已知，不产生预警。
        ///
        /// 用于用户在设置里关掉再打开预警的场景：重新打开时条件往往还成立着
        /// （比如额度一直低于阈值），此时不应该再弹一次——用户已经知道了。
        ///
        /// 注意这与「清空记录」是相反的操作：清空会让下一次 update 把当前所有
        /// 条件当成新跃迁，从而立刻触发。混用这两个语义会漏预警或多预警。
        func suppress(windows: [Window], failureStreak: Int, diskReadMBs: Double?, config: Config,
                      now: Date = Date()) {
            active = AlertMonitor.activeAlerts(windows: windows, failureStreak: failureStreak,
                                                diskReadMBs: diskReadMBs, config: config, now: now)
        }

        /// 清空跃迁记录。**下次 update 会把当前所有条件当成新跃迁。**
        /// 只在需要「重新判定一次」时使用（例如刚启动、或刚放宽了阈值）。
        func reset() { active.removeAll() }
    }
}
