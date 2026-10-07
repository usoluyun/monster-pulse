import AppKit
import Darwin

// 离屏渲染统一钉死深色外观。
//
// 为什么必须钉：视图不在窗口里时，`labelColor` 这类动态颜色解析不出来，文字
// 会被画成白色；而窗口背景跟随系统外观变成白色，于是白字白底——文字整个消失。
// 实测同一命令在系统浅色外观下渲染出的 PNG 一个字都没有。
//
// 顺带暴露了视觉回归的一个盲区：此前每次都先 --update 重生成基准图，外观变化
// 被基准图重建掩盖，因此这个依赖一直没被发现。钉死外观后基准图才真正可比。
//
// **必须声明在使用之前。** `main.swift` 顶层代码按顺序执行，全局量在执行到
// 声明语句之前处于「未初始化」状态。这个声明原先在文件中部，而
// `--settings-render-test` 在它之前就读取了 —— 于是 `content.appearance` 拿到
// nil，文字按系统外观解析成深色、窗口背景却是浅色，浅色下整套标签与勾选框
// 直接消失（只剩滑块、输入框这类有实心底色的控件）。
// 前向引用是「碰巧能用」的写法：编译器不报错，只有真去渲染才看得出。
let renderAppearance = NSAppearance(named: .darkAqua)!

// A broken child-process pipe must become an error rather than terminate the app.
signal(SIGPIPE, SIG_IGN)

func verify() throws {
    let realDomain = Bundle.main.bundleIdentifier ?? "MonsterPulse"
    let realConfigBefore = UserDefaults.standard.persistentDomain(forName: realDomain) as NSDictionary?
    let q = try Quota.parse(["rateLimits": ["primary": ["usedPercent": 25.0, "windowDurationMins": 300]]])
    precondition(q.windows.first?.remaining == 75)
    let mapped = try Quota.parse(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 100.0]]]])
    precondition(mapped.windows.first?.remaining == 0)
    for invalid: [String: Any] in [[:], ["rateLimits": ["primary": ["usedPercent": -1.0]]],
        ["rateLimitsByLimitId": ["other": ["primary": ["usedPercent": 20.0]]]]] {
        do { _ = try Quota.parse(invalid); throw ReadError.message("Invalid quota accepted") }
        catch ReadError.message(let value) { precondition(value != "Invalid quota accepted") }
    }
    // 系统采样。CPU 忙碌率是「相邻两次采样的 tick 差值」，所以必须等计数器
    // 真的走格才有值。
    //
    // 关键事实（实测，Apple Silicon 12 核）：host_statistics 返回的 CPU tick
    // 计数器约每 1 秒才更新一次。零增量比例：间隔 10ms 为 13/15、50ms 为
    // 11/15、200ms 为 6/15、1000ms 为 0/15。也就是说任何短于 1 秒的采样都
    // 很可能读到完全相同的快照。
    //
    // 原实现固定等 100µs，因此几乎必然取不到值——之前一直 PASS 只是因为
    // 每次都在编译之后跑，进程启动与编译的残留活动让快照恰好跨过了刷新点。
    // 改成轮询到计数器变化为止，不依赖这种偶然。
    //
    // 注意这条约束同样限制了产品侧：任何想要亚秒级 CPU 读数的功能（例如低帧率
    // 动效按忙碌率调速）都拿不到有意义的数据，详见 docs/codex-dock-verification.md
    // 后续补充。
    let sampler = SystemSampler()
    _ = sampler.sample()
    var system = sampler.sample()
    var waited: UInt32 = 0
    let step: UInt32 = 50_000
    while system.cpu == nil && waited < 3_000_000 {
        usleep(step); waited += step
        system = sampler.sample()
    }
    guard let cpu = system.cpu, let memory = system.memoryFraction,
          (0...1).contains(cpu), (0...1).contains(memory) else { throw ReadError.message("系统采样失败") }

    // 窗口标题由后端返回的长度推导，不硬编码「五小时」「每周」；
    // 缺长度或非正数要落到不猜窗口的兜底文案。
    //
    // 这里用收集式断言而不是 precondition：precondition 触发 SIGTRAP，
    // stderr 在 trap 前不冲刷，失败时看不到是哪一条（实测踩过），
    // 且一次只能暴露一条。改成先跑完全部用例再汇总输出。
    var failures: [String] = []
    func expect(_ actual: String, _ expected: String, _ label: String) {
        if actual != expected { failures.append("\(label)：得到「\(actual)」，期望「\(expected)」") }
    }
    for (minutes, expected) in [(300, "5 小时窗口"), (10080, "1 周窗口"), (1440, "1 天窗口"),
                               (20160, "2 周窗口"), (120, "2 小时窗口"), (100, "100 分钟窗口")] {
        expect(QuotaFormat.windowTitle(minutes: minutes), expected, "windowTitle(\(minutes))")
    }
    // 90 分钟不是整小时，不能塌缩成「1 小时窗口」——窗口长度以服务返回为准
    expect(QuotaFormat.windowTitle(minutes: 90), "90 分钟窗口", "windowTitle(90) 非整小时")
    for missing in [nil, 0, -5] as [Int?] {
        expect(QuotaFormat.windowTitle(minutes: missing), "额度窗口", "windowTitle(\(String(describing: missing)))")
    }

    // 倒计时：已到期、纯分、纯小时、天+小时；整小时不能退化成「60 分后」
    let now = Date()
    for (offset, expected) in [(0.0, "已到期"), (-3600.0, "已到期"),
                               (60.0 * 30, "30 分后"), (3600.0 * 3, "3 小时后"),
                               (3600.0 * 3 + 60.0 * 12, "3 小时 12 分后"),
                               (86400.0 * 5, "5 天后"), (86400.0 * 2 + 3600.0 * 6, "2 天 6 小时后")] {
        expect(QuotaFormat.countdown(to: now.addingTimeInterval(offset), now: now),
               expected, "countdown(+\(Int(offset))s)")
    }

    // Dock 菜单结构。真实弹出只能在 Dock 上右键，没法注入，所以这里断言的是
    // 构造结果：状态项禁用、动作项启用且绑定了 target/action、加载中禁用刷新。
    // 「autoenablesItems 必须为 false」依据官方文档（NSMenuItem.isEnabled 在
    // autoenablesItems 为真时无效），不是实测结论——无法从 Swift 触发验证路径。
    let menuNow = Date(timeIntervalSince1970: 1_767_225_600)
    let demoQuota = Quota(windows: [
        QuotaWindow(used: 8, minutes: 300, resetsAt: menuNow.addingTimeInterval(3 * 3600 + 12 * 60)),
        QuotaWindow(used: 10, minutes: 10080, resetsAt: menuNow.addingTimeInterval(5 * 86400 + 15 * 3600)),
    ])
    final class MenuTarget: NSObject {}
    let menuTarget = MenuTarget()
    defer { _ = menuTarget }

    func checkMenu(_ menu: NSMenu, _ label: String,
                   enabledTitles: [String], disabledTitles: [String]) {
        if menu.autoenablesItems { failures.append("\(label)：autoenablesItems 必须为 false") }
        let enabled = Set(menu.items.filter(\.isEnabled).map(\.title))
        let disabled = Set(menu.items.filter { !$0.isEnabled && !$0.isSeparatorItem }.map(\.title))
        for want in enabledTitles where !enabled.contains(want) {
            failures.append("\(label)：缺少应启用的项「\(want)」")
        }
        for want in disabledTitles where !disabled.contains(want) {
            failures.append("\(label)：缺少应禁用的项「\(want)」")
        }
        // 动作项必须真的绑上 target 与 action，否则点了不会有反应
        for item in menu.items where item.title == "立即刷新额度" {
            if item.action == nil || item.target == nil {
                failures.append("\(label)：刷新项缺少 target/action")
            }
        }
    }

    checkMenu(AppDelegate.buildDockMenu(target: menuTarget, quota: demoQuota, stale: false,
                                        loading: false, errorText: nil, cpu: 0.42, gpu: 0.30, memory: 0.61,
                                        now: menuNow),
              "正常状态",
              enabledTitles: ["立即刷新额度", "打开详情", "退出 Monster Pulse"],
              disabledTitles: ["5 小时窗口　剩余 92%", "CPU　42%", "GPU　30%", "内存　61%"])
    // 查询进行中必须禁用刷新：对应 refresh() 的 !loading 守卫，
    // 避免用户连点叠加查询
    checkMenu(AppDelegate.buildDockMenu(target: menuTarget, quota: demoQuota, stale: false,
                                        loading: true, errorText: nil, cpu: 0.42, gpu: 0.30, memory: 0.61,
                                        now: menuNow),
              "加载中",
              enabledTitles: ["打开详情", "退出 Monster Pulse"],
              disabledTitles: ["正在查询…"])
    // 无数据时不能出现「旧数据，仅供参考」——没有快照就说旧数据不成立
    let noDataTitles = AppDelegate.buildDockMenu(target: menuTarget, quota: nil, stale: true,
                                                 loading: false, errorText: "查询失败",
                                                 cpu: nil, gpu: nil, memory: nil, now: menuNow)
        .items.map(\.title)
    for bogus in ["旧数据，仅供参考", "5 小时窗口　剩余 92%"] where noDataTitles.contains(bogus) {
        failures.append("无数据状态不应出现「\(bogus)」")
    }

    // Config 的越界夹取与持久化。直接往 UserDefaults 写脏值再 load()，
    // 验证「配置文件被手改或来自旧版本」时不会让定时器行为失控。
    let domain = "local.monsterpulse.selftest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    Config.registerDefaults(defaults: defaults)
    defer { defaults.removePersistentDomain(forName: domain) }
    func withConfigDomain<T>(_ body: () -> T) -> T {
        defaults.removePersistentDomain(forName: domain)
        // register 的注册域挂在 app 域上，这里直接改写同一批 key
        return body()
    }
    withConfigDomain {
        defaults.set(0.0, forKey: "systemSampleInterval")       // 越下界
        defaults.set(9999.0, forKey: "quotaRefreshInterval")    // 越上界
        defaults.set(Double.nan, forKey: "systemSampleInterval")
        let clamped = Config.load(defaults: defaults)
        if clamped.systemInterval != Config.defaultSystemInterval {
            failures.append("Config.load 越界 systemInterval 应回退默认，得到 \(clamped.systemInterval)")
        }
        if clamped.quotaInterval != Config.defaultQuotaInterval {
            failures.append("Config.load 越界 quotaInterval 应回退默认，得到 \(clamped.quotaInterval)")
        }
        // 合法区间内的值必须被保留，不能被误夹
        defaults.set(7.0, forKey: "systemSampleInterval")
        defaults.set(45.0, forKey: "quotaRefreshInterval")
        let kept = Config.load(defaults: defaults)
        if kept.systemInterval != 7.0 || kept.quotaInterval != 45.0 {
            failures.append("Config.load 未保留合法值，得到 \(kept.systemInterval)/\(kept.quotaInterval)")
        }
        // 容差应随间隔缩放，且不低于 1 秒
        if kept.systemTolerance < 1 { failures.append("systemTolerance 不得小于 1 秒") }
        if kept.quotaTolerance < 1 { failures.append("quotaTolerance 不得小于 1 秒") }
        defaults.removeObject(forKey: "systemSampleInterval")
        defaults.removeObject(forKey: "quotaRefreshInterval")
    }

    // 额度预警。三条规则 + 跃迁去重都要覆盖，去重是这里最容易写错的地方：
    // 条件持续成立时不能反复触发，否则 120 秒轮询会把 Dock 一直打得跳。
    let alertNow = Date(timeIntervalSince1970: 1_767_225_600)
    let alertConfig = Config.default
    func alertWindows(remaining: Int, resetIn: TimeInterval?) -> [AlertMonitor.Window] {
        [AlertMonitor.Window(minutes: 300, remaining: remaining,
                             resetsAt: resetIn.map { alertNow.addingTimeInterval($0) })]
    }
    func keys(_ set: Set<String>) -> Set<String> { set }
    func expectAlerts(_ actual: Set<String>, _ expected: Set<String>, _ label: String) {
        if actual != expected {
            let missing = expected.subtracting(actual).sorted().joined(separator: ",")
            let extra = actual.subtracting(expected).sorted().joined(separator: ",")
            failures.append("\(label)：缺[\(missing)] 多[\(extra)]")
        }
    }

    // 额度充足、无重置临近、无失败 → 无预警
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 3600 * 3),
                                               failureStreak: 0, diskReadMBs: nil, config: alertConfig, now: alertNow)),
                 [], "正常状态不应有预警")
    // 剩余 15% 低于默认阈值 20% → 触发；20% 恰好等于阈值不算越线（阈值向上取整）
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 15, resetIn: 3600 * 3),
                                               failureStreak: 0, diskReadMBs: nil, config: alertConfig, now: alertNow)),
                 ["low-quota"], "剩余 15% 应触发额度预警")
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 20, resetIn: 3600 * 3),
                                               failureStreak: 0, diskReadMBs: nil, config: alertConfig, now: alertNow)),
                 [], "剩余 20% 等于阈值不应触发")
    // 重置临近：默认提前 30 分钟
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 60 * 20),
                                               failureStreak: 0, diskReadMBs: nil, config: alertConfig, now: alertNow)),
                 ["reset-soon-0"], "20 分钟后重置应触发")
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 60 * 40),
                                               failureStreak: 0, diskReadMBs: nil, config: alertConfig, now: alertNow)),
                 [], "40 分钟后重置不应触发")
    // 连续失败默认 3 次：2 次不报、3 次才报
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 3600 * 3),
                                               failureStreak: 2, diskReadMBs: nil, config: alertConfig, now: alertNow)),
                 [], "连续失败 2 次不应触发")
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 3600 * 3),
                                               failureStreak: 3, diskReadMBs: nil, config: alertConfig, now: alertNow)),
                 ["query-failed"], "连续失败 3 次应触发")
    // 关闭预警后一律不触发
    var muted = Config.default; muted.setAlertsEnabled(false)
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 1, resetIn: 60),
                                               failureStreak: 99, diskReadMBs: nil, config: muted, now: alertNow)),
                 [], "关闭预警后不应有任何预警")

    // 跃迁去重：同一条件持续成立只触发一次，条件消失后再次成立才重新触发。
    let tracker = AlertMonitor.Tracker()
    let low = alertWindows(remaining: 15, resetIn: 3600 * 3)
    let normal = alertWindows(remaining: 92, resetIn: 3600 * 3)
    let firstFire = tracker.update(windows: low, failureStreak: 0, diskReadMBs: nil, config: alertConfig, now: alertNow)
    if firstFire.map(\.key) != ["low-quota"] {
        failures.append("Tracker 首次越线应产生 low-quota，得到 \(firstFire.map(\.key))")
    }
    for round in 1...5 {
        let repeatFire = tracker.update(windows: low, failureStreak: 0, diskReadMBs: nil, config: alertConfig,
                                        now: alertNow.addingTimeInterval(TimeInterval(round * 120)))
        if !repeatFire.isEmpty {
            failures.append("Tracker 在条件持续成立时第 \(round) 轮重复触发了 \(repeatFire.map(\.key))")
            break
        }
    }
    // 条件消失后清空，再次越线应重新触发
    _ = tracker.update(windows: normal, failureStreak: 0, diskReadMBs: nil, config: alertConfig,
                       now: alertNow.addingTimeInterval(720))
    let reFire = tracker.update(windows: low, failureStreak: 0, diskReadMBs: nil, config: alertConfig,
                               now: alertNow.addingTimeInterval(840))
    if reFire.map(\.key) != ["low-quota"] {
        failures.append("Tracker 在条件消失后再次越线应重新触发，得到 \(reFire.map(\.key))")
    }
    // suppress()：关掉再打开预警时，条件通常还成立着，不应立刻再弹一次。
    // 这与 reset() 语义相反——reset() 清空记录，下次会把当前条件当成新跃迁。
    tracker.reset()
    let reFireAfterReset = tracker.update(windows: low, failureStreak: 0, diskReadMBs: nil, config: alertConfig,
                                          now: alertNow.addingTimeInterval(960))
    if reFireAfterReset.map(\.key) != ["low-quota"] {
        failures.append("Tracker.reset() 后应把当前条件当作新跃迁，得到 \(reFireAfterReset.map(\.key))")
    }
    tracker.suppress(windows: low, failureStreak: 0, diskReadMBs: nil, config: alertConfig, now: alertNow)
    let afterSuppress = tracker.update(windows: low, failureStreak: 0, diskReadMBs: nil, config: alertConfig,
                                       now: alertNow.addingTimeInterval(1080))
    if !afterSuppress.isEmpty {
        failures.append("Tracker.suppress() 后不应立即触发，得到 \(afterSuppress.map(\.key))")
    }
    // suppress 之后条件再次成立仍要能触发（说明 suppress 没有把记录写死）
    _ = tracker.update(windows: normal, failureStreak: 0, diskReadMBs: nil, config: alertConfig,
                       now: alertNow.addingTimeInterval(1200))
    let afterSuppressRefire = tracker.update(windows: low, failureStreak: 0, diskReadMBs: nil, config: alertConfig,
                                             now: alertNow.addingTimeInterval(1320))
    if afterSuppressRefire.map(\.key) != ["low-quota"] {
        failures.append("suppress 后条件再次越线应重新触发，得到 \(afterSuppressRefire.map(\.key))")
    }
    // 预警文案必须带上真实数值，便于排障
    let sampleAlert = AlertMonitor.message(for: "low-quota", windows: low, failureStreak: 0,
                                          config: alertConfig, now: alertNow)
    if !sampleAlert.body.contains("15") || !sampleAlert.body.contains("20") {
        failures.append("low-quota 文案应含剩余 15% 与阈值 20%，得到「\(sampleAlert.body)」")
    }

    // 时间进度参考线。只在数据不自洽时返回 nil——缺窗口长度、或 resetsAt
    // 距现在比整个窗口还远（时钟偏移或陈旧数据，此时画出来的位置是假的）。
    // 边界值是合法的：刚进入窗口返回 0.0（画在左端），已过期夹到 1.0。
    let paceNow = Date(timeIntervalSince1970: 1_767_225_600)
    func pace(_ resetIn: TimeInterval, _ minutes: Int) -> Double? {
        QuotaFormat.windowProgress(resetsAt: paceNow.addingTimeInterval(resetIn),
                                   windowMinutes: minutes, now: paceNow)
    }
    func expectPace(_ actual: Double?, _ expected: Double?, _ label: String) {
        switch (actual, expected) {
        case (nil, nil): return
        case (let a?, let e?):
            if abs(a - e) > 0.001 { failures.append("\(label)：得到 \(a)，期望 \(e)") }
        default:
            failures.append("\(label)：得到 \(actual.map { "\($0)" } ?? "nil")，期望 \(expected.map { "\($0)" } ?? "nil")")
        }
    }
    // 300 分钟窗口，剩 150 分钟 → 已过一半
    expectPace(pace(150 * 60, 300), 0.5, "300 分钟窗口剩 150 分钟")
    expectPace(pace(0, 300), 1.0, "刚好重置")
    expectPace(pace(300 * 60, 300), 0.0, "刚进入窗口应为 0 而不是 nil")
    // 已过期不是无效数据：时间确实用完了，夹到 1.0
    expectPace(pace(-600, 300), 1.0, "已过期夹到 1")
    expectPace(pace(600 * 60, 300), nil, "剩余超过窗口长度返回 nil")
    expectPace(pace(60, 0), nil, "缺窗口长度返回 nil")
    expectPace(pace(60, -5), nil, "非法窗口长度返回 nil")

    // 内存与磁盘格式化。速率与容量的单位切换必须正确——写错一个数量级
    // 就会把 450 MB/s 显示成 450 GB/s，正是最需要说准的那类数。
    func expectText(_ actual: String, _ expected: String, _ label: String) {
        if actual != expected { failures.append("\(label)：得到「\(actual)」，期望「\(expected)」") }
    }
    expectText(SystemFormat.bytes(1.6e9), "1.5 GB", "1.6e9 字节")
    expectText(SystemFormat.bytes(860e6), "820 MB", "860MB 字节")
    expectText(SystemFormat.bytes(4.5e3), "4 KB", "小于 1MB 时用 KB")
    expectText(SystemFormat.bytes(nil), "—", "nil 字节数")
    expectText(SystemFormat.bytes(-1), "—", "负值字节数")
    expectText(SystemFormat.rate(450e6), "429 MB/s", "450MB/s 速率")
    expectText(SystemFormat.rate(1.5e9), "1.4 GB/s", "超 1000MB/s 用 GB/s")
    expectText(SystemFormat.rate(500), "0 KB/s", "小于 1KB/s 时用 KB/s")
    expectText(SystemFormat.rate(nil), "—", "nil 速率")
    expectText(SystemFormat.percent(0.425), "42%", "百分比")
    expectText(SystemFormat.percent(nil), "—", "nil 百分比")

    // 磁盘读入预警。默认阈值 200 MB/s：低于不报、等于不报（用 >= 所以等于会报，
    // 这里按实际语义断言）、高于必报。速率缺失（首帧无差值基准）时不报——
    // 拿不到数据不等于正常，也不等于异常，不该在缺数据时打扰用户。
    func diskAlerts(_ mbs: Double?) -> Set<String> {
        AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 3600 * 3),
                                  failureStreak: 0, diskReadMBs: mbs,
                                  config: alertConfig, now: alertNow)
    }
    expectAlerts(diskAlerts(10), [], "磁盘 10MB/s 不应触发")
    expectAlerts(diskAlerts(200), ["disk-io"], "磁盘等于阈值应触发")
    expectAlerts(diskAlerts(900), ["disk-io"], "磁盘 900MB/s 应触发")
    expectAlerts(diskAlerts(nil), [], "磁盘速率缺失不应触发")
    expectAlerts(diskAlerts(-5), [], "负速率不应触发")
    // 文案里的速率要与传入值一致（MB/s 进、MB/s 出），不能出现二次换算
    let diskAlert = AlertMonitor.message(for: "disk-io", windows: [], failureStreak: 0,
                                         diskReadMBs: 900, config: alertConfig, now: alertNow)
    if !diskAlert.body.contains("900 MB/s") || !diskAlert.body.contains("200 MB/s") {
        failures.append("disk-io 文案应含当前 900 MB/s 与阈值 200 MB/s，得到「\(diskAlert.body)」")
    }

    // 代理规范化。这是 GUI 应用能用上代理的关键一步：Dock 启动的应用不读
    // .zshrc，必须由用户在设置里填；填错时宁可当作「不设代理」也不要注入
    // 一个坏值导致查询更难排查。
    func expectProxy(_ raw: String?, _ expected: String?, _ label: String) {
        let actual = ProxySetting.normalize(raw)
        if actual != expected {
            failures.append("\(label)：得到 \(actual.map { "「\($0)」" } ?? "nil")，"
                + "期望 \(expected.map { "「\($0)」" } ?? "nil")")
        }
    }
    expectProxy("http://127.0.0.1:12334", "http://127.0.0.1:12334", "完整 URL 原样保留")
    expectProxy("socks5://127.0.0.1:12334", "socks5://127.0.0.1:12334", "socks5 scheme 保留")
    expectProxy("127.0.0.1:12334", "http://127.0.0.1:12334", "省略 scheme 按 http 补全")
    expectProxy("  127.0.0.1:12334  ", "http://127.0.0.1:12334", "首尾空白应被裁掉")
    expectProxy("", nil, "空串视为不设代理")
    expectProxy("   ", nil, "纯空白视为不设代理")
    expectProxy(nil, nil, "nil 视为不设代理")
    expectProxy("http://", nil, "只有 scheme 没有主机名应拒绝")
    expectProxy("http://:12334", nil, "缺少主机名应拒绝")
    expectProxy("http://127.0.0.1:abc", nil, "非法端口应拒绝")
    // 环境注入：大小写都要设，否则"配了却没生效"极难排查
    let injected = ProxySetting.environment(from: ["PATH": "/usr/bin"],
                                             proxy: "http://127.0.0.1:12334")
    for key in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
        if injected[key] != "http://127.0.0.1:12334" {
            failures.append("环境注入缺少或错误的 \(key)：\(injected[key] ?? "nil")")
        }
    }
    if injected["PATH"] != "/usr/bin" { failures.append("环境注入丢了原有 PATH") }
    if !ProxySetting.environment(from: ["PATH": "/x"], proxy: "  ").keys.contains("PATH") {
        failures.append("不设代理时不应改动环境")
    }

    for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
        if NetworkStatus.proxyEnabled([key: 1]) != true { failures.append("系统代理开关 \(key)") }
    }
    if NetworkStatus.proxyEnabled(["HTTPProxy": "localhost", "HTTPEnable": 0]) != false { failures.append("代理地址不能当成开启") }
    let probeArgs = NetworkMonitor.probeArguments(proxy: "socks5://localhost:1080")
    if !probeArgs.contains("socks5://localhost:1080") || !probeArgs.contains("--disable")
        || !probeArgs.contains("--noproxy") || probeArgs.last != "https://cloudflare.com/cdn-cgi/trace" {
        failures.append("应用代理探测必须显式指定代理并禁用隐式绕过")
    }
    if NetworkStatus.proxyEnabled(nil) != nil { failures.append("无法读取代理时不能报关闭") }
    if NetworkStatus.parseTrace("ip=203.0.113.1\nloc=US\ncolo=HKG")?.country != "US" { failures.append("国家要读 loc 而不是 colo") }
    if NetworkStatus.parseTrace("ip=2001:db8::1\nloc=HK")?.country != "HK" { failures.append("IPv6 出口解析") }
    for invalid in ["ip=bad\nloc=US", "ip=203.0.113.1\nloc=XX", "ip=203.0.113.1\nloc=bad", "loc=US"] {
        if NetworkStatus.parseTrace(invalid) != nil { failures.append("无效出口探测不可猜国家") }
    }
    for (seconds, expected) in [(0.0, "0m"), (59.0, "1m"), (120.0, "2m"), (3601.0, "2h"), (86401.0, "2d")] {
        expect(NetworkStatus.resetLabel(now.addingTimeInterval(seconds), now: now) ?? "?", expected, "短重置倒计时")
    }

    if !failures.isEmpty {
        for line in failures { fputs("FAIL  \(line)\n", stderr) }
        throw ReadError.message("自检失败 \(failures.count) 项")
    }
    let realConfigAfter = UserDefaults.standard.persistentDomain(forName: realDomain) as NSDictionary?
    if realConfigBefore != realConfigAfter {
        throw ReadError.message("自检不得改变真实配置域")
    }
    print("PASS: quota parsing, missing/invalid/other buckets, CPU and memory sampling, window title and countdown formatting, dock menu structure, config clamping, quota alerts")
}

if CommandLine.arguments.contains("--self-test") {
    do { try verify(); exit(0) } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--network-probe") {
    let monitor = NetworkMonitor()
    monitor.poll(proxy: Config.load().effectiveProxy, force: true) {
        guard !monitor.loading else { return }
        print("country=\(monitor.exit?.country ?? "?") proxy=\(monitor.probeProxyEnabled.map { $0 ? "on" : "off" } ?? "unknown")")
        exit(monitor.exit == nil ? 1 : 0)
    }
    RunLoop.main.run()
    exit(1)
}

if CommandLine.arguments.contains("--draw-bench") {
    // 量化单次 draw 成本，用来定低帧率动效的帧率预算。
    // Dock 图标走 dockTile 离屏渲染，没有 GPU 合成可借力——每帧都要 CPU 重画，
    // 所以单帧成本 × 帧率就是动效的额外 CPU 预算。
    let view = DockView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    view.remaining = 92; view.cpu = 0.42; view.gpu = 0.3
    view.rails = [DockView.Rail(used: 0.38, elapsed: 0.45)]
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    func timeIt(_ label: String, _ n: Int) {
        // 预热，避免把首帧的一次性开销算进稳态
        for _ in 0..<50 { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let ns = DispatchTime.now().uptimeNanoseconds - t0
        let per = Double(ns) / Double(n) / 1_000_000
        let fps = 1000 / per
        let cpu = per * fps / 10        // ms × 次/秒 = ms/s，÷10 换成百分比
        let pad = label + String(repeating: " ", count: max(0, 24 - label.count))
        print(pad + String(format: "单帧 %6.3f ms   → %5.1f fps 时额外 CPU %5.2f%%",
                           per, fps, cpu))
    }
    print("Dock 单帧 draw 成本（Release -O，Apple Silicon）")
    print("场景                     单帧耗时         换算成帧率的额外 CPU")
    print(String(repeating: "-", count: 66))
    timeIt("静止同值(命中缓存)", 2000)
    view.remaining = 91   // 换字，触发 glyph 缓存新条目
    timeIt("数字变化(新字形)", 2000)
    view.remaining = 92
    timeIt("回到同值(缓存命中)", 2000)
    view.stale = true    // 触发 backdrop 重建
    timeIt("stale 切换(重建背景)", 2000)
    print("\n注：上表不含 dock tile 合成到屏幕的开销，那部分由 WindowServer 承担，")
    print("    无法从进程内测得，实际帧率预算应在此基础上留余量。")
    exit(0)
}
if CommandLine.arguments.contains("--render-test") {
    // 把 Dock 图标离屏渲染成 PNG，用于回归对比：改 draw() 后要确认视觉未变。
    // 用法: MonsterPulse --render-test <out.png> [remaining] [cpu] [memory] [stale]
    let args = Array(CommandLine.arguments.dropFirst(2))   // 跳过程序路径与本 flag
    let out = args.first ?? "/tmp/codexdock-render.png"
    let view = DockView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    // remaining 传 "nil" 表示无额度数据（横杠「—」），用于覆盖
    // 「没有数字时不该标 OLD」这条分支
    view.remaining = args.count > 1 ? (args[1] == "nil" ? nil : Int(args[1])) : 92
    view.cpu = args.count > 2 ? Double(args[2]) : 0.42
    // 第 4 位两代语法：旧的是 memory（数字），新的是 stale/none。识别到数字就
    // 按旧语法跳位——旧脚本不至于全坏，新脚本用新位置。
    let fourth = args.count > 3 ? args[3] : "none"
    let legacy = Double(fourth) != nil
    view.stale = legacy ? (args.count > 4 && args[4] == "stale")
                        : (fourth == "stale")
    let metersSlot = legacy ? 5 : 4
    if args.count > metersSlot {
        let meters = args[metersSlot]
        view.showCPU = meters != "no-cpu" && meters != "no-both"
        view.showGPU = meters != "no-gpu" && meters != "no-both"
    }
    // extras：gpu=占用 / rail=<used>/<elapsed>（主窗口轨）/
    // rail2=<used>/<elapsed>（周窗口轨）。elapsed 传 -1 表示无时间信息。
    let extrasSlot = metersSlot + 1
    let extras = args.count > extrasSlot ? args[extrasSlot].split(separator: ",").map(String.init) : []
    for extra in extras {
        // maxSplits=1 且允许没有 "="：无值开关（nogpu / nogpumeter）和
        // 带值参数（gpu=0.5）要分开处理。原先用 `guard parts.count == 2` 一刀切，
        // 结果 nogpumeter 被静默跳过——「配置关闭 GPU」的用例照样画着绿条，
        // 而它因为没传 gpu 又碰巧画对了。无值开关被跳过时不会报错，只会
        // 让夹具悄悄退化成另一种状态。
        let parts = extra.split(separator: "=", maxSplits: 1).map(String.init)
        let key = parts[0]
        if key == "country", parts.count == 2 { view.country = parts[1]; continue }
        if key == "proxy", parts.count == 2 { view.proxyEnabled = parts[1] == "on" ? true : (parts[1] == "off" ? false : nil); continue }
        if key == "reset", parts.count == 2, let seconds = Double(parts[1]) {
            let now = Date(timeIntervalSince1970: 1_767_225_600)
            view.resetLabel = NetworkStatus.resetLabel(now.addingTimeInterval(seconds), now: now)
            continue
        }
        if key == "nogpu" { view.gpu = nil; continue }
        if key == "nogpumeter" { view.showGPU = false; continue }
        if key == "rail" || key == "rail2" {
            // rail 的值是 "used/elapsed" 复合形式，不走通用数值解析
            let pieces = parts[1].split(separator: "/").compactMap(Double.init)
            guard pieces.count == 2 else { continue }
            let rail = DockView.Rail(used: min(1, max(0, pieces[0])),
                                     elapsed: pieces[1] < 0 ? nil : min(1, max(0, pieces[1])))
            if key == "rail" {
                view.rails = [rail]
            } else if !view.rails.isEmpty {
                view.rails.append(rail)
            }
            continue
        }
        guard parts.count == 2, let value = Double(parts[1]) else { continue }
        if key == "gpu" { view.gpu = value }
    }
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    // Exercise changing the switches on an existing view, including cached tracks.
    let desiredCPU = view.showCPU, desiredGPU = view.showGPU
    view.showCPU = !desiredCPU; view.showGPU = !desiredGPU
    let warmup = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: warmup)
    view.showCPU = desiredCPU; view.showGPU = desiredGPU
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) remaining=\(view.remaining ?? -1) cpu=\(view.cpu ?? -1) gpu=\(view.gpu ?? -1) stale=\(view.stale) rails=\(view.rails.count)")
    exit(0)
}
if CommandLine.arguments.contains("--settings-render-test") {
    // 把设置窗口离屏渲染成 PNG。与 --details-render-test 同一手法。
    // 用途：验证面板布局（新增控件有没有被挤出可视区），以及让用户直接看到
    // 每个配置项长什么样，不必靠猜。
    // 用法: MonsterPulse --settings-render-test <out.png> [proxy|dns|nometers|alerts-off|login-on|login-off|full]
    let args = Array(CommandLine.arguments.dropFirst(2))
    let out = args.first ?? "/tmp/monsterpulse-settings.png"
    let state = args.count > 1 ? args[1] : "full"
    // 用成员初始化而不是 setXxx()：那些 setter 会写 UserDefaults，跑一次渲染
    // 就会改掉用户的真实配置。渲染是只读操作，不该有持久化副作用。
    let base = Config.default
    let config: Config
    switch state {
    case "nometers":   config = Config(systemInterval: base.systemInterval, quotaInterval: base.quotaInterval,
                                      showCPU: false, showMemory: false, showGPU: base.showGPU, alertsEnabled: base.alertsEnabled,
                                      alertQuotaThreshold: base.alertQuotaThreshold,
                                      alertResetLeadMinutes: base.alertResetLeadMinutes,
                                      alertFailureStreak: base.alertFailureStreak,
                                      diskAlertMBs: base.diskAlertMBs, proxyURL: base.proxyURL)
    case "alerts-off": config = Config(systemInterval: base.systemInterval, quotaInterval: base.quotaInterval,
                                      showCPU: base.showCPU, showMemory: base.showMemory, showGPU: base.showGPU, alertsEnabled: false,
                                      alertQuotaThreshold: base.alertQuotaThreshold,
                                      alertResetLeadMinutes: base.alertResetLeadMinutes,
                                      alertFailureStreak: base.alertFailureStreak,
                                      diskAlertMBs: base.diskAlertMBs, proxyURL: base.proxyURL)
    case "dns":        config = Config(systemInterval: base.systemInterval, quotaInterval: base.quotaInterval,
                                      showCPU: base.showCPU, showMemory: base.showMemory,
                                      showGPU: base.showGPU, alertsEnabled: base.alertsEnabled,
                                      alertQuotaThreshold: base.alertQuotaThreshold,
                                      alertResetLeadMinutes: base.alertResetLeadMinutes,
                                      alertFailureStreak: base.alertFailureStreak,
                                      diskAlertMBs: base.diskAlertMBs, proxyURL: "")
    default:           config = Config(systemInterval: base.systemInterval, quotaInterval: base.quotaInterval,
                                      showCPU: base.showCPU, showMemory: base.showMemory,
                                      showGPU: base.showGPU, alertsEnabled: base.alertsEnabled,
                                      alertQuotaThreshold: base.alertQuotaThreshold,
                                      alertResetLeadMinutes: base.alertResetLeadMinutes,
                                      alertFailureStreak: base.alertFailureStreak,
                                      diskAlertMBs: base.diskAlertMBs, proxyURL: "127.0.0.1:12334")
    }
    let controller = SettingsWindowController(config: config) { _ in }
    // 自启状态一律钉死，不读系统真值。
    //
    // 不钉的话基线图会随「用户是否开启过自启」「跑的是 .build 还是
    // /Applications」而漂移——两者都会变，而基准图不该跟着变。只有
    // login-on 一个夹具画开启态，其余（含 full）都画关闭态。
    // 读系统真值那条路径由真机点验覆盖，不由基准图覆盖。
    controller.renderLaunchAtLoginOverride = (state == "login-on")
    controller.renderAppearance = renderAppearance
    controller.renderToPNG(out)
    print("wrote \(out) state=\(state)")
    print("layout: \(controller.layoutDiagnostics())")
    exit(0)
}

if CommandLine.arguments.contains("--dock-menu-dump") {
    // 把 Dock 菜单结构打成纯文本，供人工排障与自检断言。
    // 格式：每行 "<enabled|disabled>\t<title>"，分隔项显示为 disabled\t--
    // 用法: MonsterPulse --dock-menu-dump <normal|no-data|stale|error|loading>
    let args = Array(CommandLine.arguments.dropFirst(2))
    let state = args.first ?? "normal"
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    let demo = Quota(windows: [
        QuotaWindow(used: 8, minutes: 300,
                    resetsAt: now.addingTimeInterval(3 * 3600 + 12 * 60)),
        QuotaWindow(used: 10, minutes: 10080,
                    resetsAt: now.addingTimeInterval(5 * 86400 + 15 * 3600)),
    ])
    // target 必须活到菜单构建之后：NSMenuItem.target 不持有强引用，
    // 传临时 NSObject() 会在构建期间就被释放（编译器会就此告警）。
    final class MenuTarget: NSObject {}
    let target = MenuTarget()
    let menu: NSMenu
    switch state {
    case "no-data":  menu = AppDelegate.buildDockMenu(target: target, quota: nil, stale: false,
                                                     loading: false, errorText: nil,
                                                     cpu: 0.42, gpu: 0.30, memory: 0.61, now: now)
    case "stale":     menu = AppDelegate.buildDockMenu(target: target, quota: demo, stale: true,
                                                     loading: false, errorText: nil,
                                                     cpu: 0.42, gpu: 0.30, memory: 0.61, now: now)
    case "error":     menu = AppDelegate.buildDockMenu(target: target, quota: nil, stale: true,
                                                     loading: false,
                                                     errorText: "Codex 查询超时或进程退出；请检查 CLI 登录状态和网络",
                                                     cpu: 0.42, gpu: 0.30, memory: 0.61, now: now)
    case "loading":   menu = AppDelegate.buildDockMenu(target: target, quota: demo, stale: false,
                                                     loading: true, errorText: nil,
                                                     cpu: 0.42, gpu: 0.30, memory: 0.61, now: now)
    default:          menu = AppDelegate.buildDockMenu(target: target, quota: demo, stale: false,
                                                     loading: false, errorText: nil,
                                                     cpu: 0.42, gpu: 0.30, memory: 0.61, now: now)
    }
    defer { _ = target }
    print("state=\(state)")
    for item in menu.items {
        let title = item.isSeparatorItem ? "--" : item.title
        // 把 action 选择器一并打出来，人工点验时能对照「这一项该触发什么」，
        // 而不是只能看标题对不对。Dock 菜单的 target/action 不由系统分发，
        // 实际会走到哪个方法是这次点验最需要确认的东西。
        let action = item.action.map { NSStringFromSelector($0) } ?? "-"
        print("\(item.isEnabled ? "enabled" : "disabled")\t\(title)\t\(action)")
    }
    exit(0)
}
if CommandLine.arguments.contains("--details-render-test") {
    // 把详情窗口离屏渲染成 PNG，用于视觉回归：改 DetailsView 后要确认外观未变。
    // 用法: MonsterPulse --details-render-test <out.png> [normal|no-data|stale|error|loading]
    //
    // 与 --render-test 同一手法：AppKit 视图可以脱离窗口用 cacheDisplay 渲染，
    // 不需要真实窗口也不需要 AppKit 事件循环。
    let args = Array(CommandLine.arguments.dropFirst(2))
    let out = args.first ?? "/tmp/monsterpulse-details.png"
    let state = args.count > 1 ? args[1] : "normal"
    let inset: CGFloat = 22
    let width: CGFloat = 460
    let bottomBar: CGFloat = 56

    let details = DetailsView(frame: .zero)
    // 固定基准时间，不用 Date()：footer 会渲染「更新 HH:mm:ss」，
    // 用真实时间会让每次渲染都不同，视觉回归逐像素比对必然全 FAIL。
    let now = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01 08:00:00 UTC
    // 用例数据也要走真实的 windowTitle / countdown，而不是把文案写死。
    // 写死字面量会让这两个函数在视觉回归里完全不被执行——实测把 countdown
    // 改成永远不出分钟、视觉回归仍然 10/10 全过，回归对这段逻辑是盲的。
    // 改成传固定时间戳后，同一处改动会被 details-normal 判 FAIL。
    let windows: [(title: String, used: Int, remaining: Int, reset: String?)] = [
        (QuotaFormat.windowTitle(minutes: 300), 8, 92,
         QuotaFormat.countdown(to: now.addingTimeInterval(3 * 3600 + 12 * 60), now: now)),
        (QuotaFormat.windowTitle(minutes: 10080), 10, 90,
         QuotaFormat.countdown(to: now.addingTimeInterval(5 * 86400 + 15 * 3600), now: now)),
    ]
    // 配置关掉的指标要能在渲染里体现，否则视觉回归覆盖不到这条分支
    let showCPU = !state.hasSuffix("-no-meters")
    let showMemory = showCPU
    // 固定的系统读数，磁盘速率刻意给一个高位（阈值 200MB/s 的 2.25 倍），
    // 让「速率条 + 明细行」在基准图里真的有内容可看。GPU 设为满载，
    // 还原跑本地模型时的真实形态（CPU 闲、GPU 忙）。
    let demoReading = SystemReading(cpu: 0.42, memoryFraction: 0.61,
                                    compressedBytes: 2.1 * 1_073_741_824,
                                    diskReadBytesPerSecond: 450 * 1_048_576,
                                    diskWriteBytesPerSecond: 0,
                                    swapUsedBytes: 1.6 * 1_073_741_824,
                                    physicalBytes: 24 * 1_073_741_824,
                                    gpu: GPUReading(deviceUtilization: 1.0,
                                                   rendererUtilization: 1.0,
                                                   tilerUtilization: 0.22,
                                                   inUseMemoryBytes: 7.5 * 1_073_741_824,
                                                   model: "Apple M4 Pro"))
    // 「GPU 不可用」状态：没有 IOAccelerator 服务时界面必须显示「—」而不是猜
    let showGPU = showCPU && state != "no-gpu"
    let readingForState: SystemReading = state == "no-gpu"
        ? SystemReading(cpu: 0.42, memoryFraction: 0.61, physicalBytes: 24 * 1_073_741_824)
        : demoReading
    let idleReading = SystemReading()
    switch state {
    case "no-data", "no-data-no-meters":
        details.update(windows: [], quotaAvailable: false, cpu: nil, reading: idleReading,
                       showCPU: showCPU, showMemory: showMemory, showGPU: showGPU,
                       updated: nil, loading: false, errorText: nil, stale: false)
    case "stale":
        details.update(windows: windows, quotaAvailable: true, cpu: 0.42, reading: readingForState,
                       showCPU: showCPU, showMemory: showMemory, showGPU: showGPU,
                       updated: now.addingTimeInterval(-600), loading: false, errorText: nil, stale: true)
    case "error":
        details.update(windows: [], quotaAvailable: false, cpu: 0.42, reading: readingForState,
                       showCPU: showCPU, showMemory: showMemory, showGPU: showGPU,
                       updated: nil, loading: false,
                       errorText: "Codex 查询超时或进程退出；请检查 CLI 登录状态和网络", stale: true)
    case "loading":
        details.update(windows: windows, quotaAvailable: true, cpu: 0.42, reading: readingForState,
                       showCPU: showCPU, showMemory: showMemory, showGPU: showGPU,
                       updated: now, loading: true, errorText: nil, stale: false)
    default:
        details.update(windows: windows, quotaAvailable: true, cpu: 0.42, reading: readingForState,
                       showCPU: showCPU, showMemory: showMemory, showGPU: showGPU,
                       updated: now, loading: false, errorText: nil, stale: false)
    }

    let content = details.preferredHeight
    let total = NSSize(width: width, height: content + inset * 2 + bottomBar)
    // 容器模拟真实窗口的 contentView，这样 details 的 frame 与线上一致
    let container = NSView(frame: NSRect(origin: .zero, size: total))
    container.appearance = renderAppearance
    // 离屏没有窗口垫底；显式解析已钉住的深色外观，避免 README 中白字透明底。
    container.wantsLayer = true
    renderAppearance.performAsCurrentDrawingAppearance {
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    details.appearance = renderAppearance
    container.addSubview(details)
    details.frame = NSRect(x: inset, y: bottomBar, width: width - inset * 2, height: content)
    container.layoutSubtreeIfNeeded()

    let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
    container.cacheDisplay(in: container.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) state=\(state) size=\(Int(total.width))x\(Int(total.height))")
    exit(0)
}
if CommandLine.arguments.contains("--probe") {
    do {
        let quota = try CodexReader.read(proxy: ProcessInfo.processInfo.environment["https_proxy"])
        for window in quota.windows {
            print("Codex: remaining=\(window.remaining)% windowMinutes=\(window.minutes.map(String.init) ?? "unknown") reset=\(window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
        }
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

final class DockView: NSView {
    var remaining: Int?
    /// 一条额度轨。两条轨（5 小时窗口 / 周窗口）用同一套画法，语义统一。
    struct Rail {
        /// 已用比例（0...1），画成填充长度——这是「用量」这个量本身。
        var used: Double
        /// 窗口时间已过的比例（0...1），画成一道竖刻度。
        var elapsed: Double?
    }
    var cpu: Double?
    /// GPU 占用（0...1）。跑本地大模型时这是判断「机器在不在算」的唯一指标，
    /// 所以进了 Dock 图标而不是只留在详情窗口。
    var gpu: Double?
    var stale = false
    var showCPU = true
    var showGPU = true
    /// 额度轨：[0] = 5 小时主窗口，[1] = 周窗口。缺失的窗口不画。
    var rails: [Rail] = []
    var country: String?
    var proxyEnabled: Bool?
    var resetLabel: String?
    // Dock 采用静态分栏；负载只在系统采样变化时重绘。
    // 缓存背景与字形，避免重复排版。
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byClipping
        return style
    }()

    private var backdrop: NSImage?
    private var backdropStale = false
    private var backdropSize: CGSize = .zero
    private var backdropRails = 0
    private var backdropMeters = ""
    private var glyphs: [String: NSImage] = [:]
    /// 字形缓存有上限，额度变化时不持续积累位图；超过上限整体重建。
    private static let glyphCacheLimit = 24

    // 数字只在变化时重排，key 覆盖「文本+字号+颜色」，取值域有界（百分比 0…100）
    private func drawGlyph(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor) {
        let key = "\(text)|\(rect.width)|\(size)|\(color.description)"
        let image: NSImage
        if let hit = glyphs[key] {
            image = hit
        } else {
            image = NSImage(size: NSSize(width: rect.width, height: size + 9), flipped: false) { rect in
                let baseFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
                let textWidth = (text as NSString).size(withAttributes: [.font: baseFont]).width
                let fittedSize = textWidth > rect.width - 2
                    ? size * (rect.width - 2) / textWidth : size
                (text as NSString).draw(in: rect, withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: fittedSize, weight: .semibold),
                    .foregroundColor: color, .paragraphStyle: DockView.paragraph])
                return true
            }
            if glyphs.count >= Self.glyphCacheLimit { glyphs.removeAll() }
            glyphs[key] = image
        }
        image.draw(in: rect)
    }

    /// 128pt 画布缩到 43pt：左侧额度数字，右侧 CPU / GPU 固定竖柱。
    /// 两根柱约 5pt 宽、23pt 高；填充始终由下向上，关掉一项不挪另一项。
    static let meterSlots = 2
    static func meterRect(slot: Int) -> NSRect {
        NSRect(x: 80 + CGFloat(slot) * 24, y: 38, width: 13.5, height: 60)
    }

    /// 底部独立的额度区：上轨 5h、下轨周额度，填充为已用比例。
    static let railWidth: CGFloat = 98
    static let railX: CGFloat = 15
    static let railHeight: CGFloat = 6
    static func railRect(_ index: Int) -> NSRect {
        NSRect(x: railX, y: 26 - CGFloat(index) * 15, width: railWidth, height: railHeight)
    }

    /// 无读数时用斜纹区分「不可用」与零负载；关闭的指标连同底槽一起隐藏。
    private func drawUnavailable(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
        NSColor.gray.setStroke()
        let hatch = NSBezierPath()
        hatch.lineWidth = 2
        for offset in stride(from: -rect.height, through: rect.width, by: 9) {
            hatch.move(to: NSPoint(x: rect.minX + offset, y: rect.minY))
            hatch.line(to: NSPoint(x: rect.minX + offset + rect.height, y: rect.maxY))
        }
        hatch.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func makeBackdrop() -> NSImage {
        NSImage(size: bounds.size, flipped: false) { rect in
            NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), xRadius: 24, yRadius: 24).fill()
            NSColor(calibratedWhite: 0.24, alpha: 1).setFill()
            // 背板按当前 rails 数画底槽。rails 变化会让 backdrop 失效重建
            // （backdropRails 记着上次画了几条），所以这里捕获的必然是最新的。
            for index in 0..<self.rails.count {
                let rail = DockView.railRect(index)
                NSBezierPath(roundedRect: rail, xRadius: 1.5, yRadius: 1.5).fill()
            }
            NSColor.darkGray.setFill()
            for slot in 0..<DockView.meterSlots where slot == 0 ? self.showCPU : self.showGPU {
                let bar = DockView.meterRect(slot: slot)
                NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if backdrop == nil || backdropStale != stale || backdropSize != bounds.size
            || backdropRails != rails.count || backdropMeters != "\(showCPU):\(showGPU)" {
            backdrop = makeBackdrop()
            backdropStale = stale
            backdropSize = bounds.size
            backdropRails = rails.count
            backdropMeters = "\(showCPU):\(showGPU)"
        }
        backdrop?.draw(in: bounds)

        // 旧快照的数字变橙色；首次查询失败没有快照，只画中性的横杠。
        let markStale = stale && remaining != nil
        let ringRect = NSRect(x: 13, y: 40, width: 57, height: 57)
        let ringCenter = NSPoint(x: ringRect.midX, y: ringRect.midY)
        let radius: CGFloat = 28.5
        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = 6
        NSColor.darkGray.setStroke(); track.stroke()
        if let remaining, remaining > 0 {
            let arc = NSBezierPath()
            arc.lineWidth = 6
            arc.appendArc(withCenter: ringCenter, radius: radius, startAngle: 90,
                          endAngle: 90 - CGFloat(min(100, max(0, remaining))) * 3.6,
                          clockwise: true)
            (markStale || remaining <= 15 ? NSColor.systemOrange : NSColor.white).setStroke()
            arc.stroke()
        }
        let numberSize: CGFloat = (remaining ?? 0) >= 100 ? 21 : 25
        drawGlyph(remaining.map(String.init) ?? "—",
                  in: NSRect(x: 17, y: 52, width: 38, height: numberSize + 9),
                  size: numberSize, color: markStale ? .systemOrange : .white)
        if remaining != nil {
            drawGlyph("%", in: NSRect(x: 54, y: 57, width: 12, height: 20),
                      size: 11, color: markStale ? .systemOrange : .white)
        }
        // 左上角网络状态：国家代码与探测路径的代理开关显示。
        drawGlyph(country ?? "?", in: NSRect(x: 14, y: 92, width: 37, height: 28),
                  size: 19, color: .white)
        let dot = NSRect(x: 55, y: 104, width: 8, height: 8)
        if let enabled = proxyEnabled {
            let shape = NSBezierPath(ovalIn: dot)
            if enabled { NSColor.white.setFill(); shape.fill() }
            else { NSColor.gray.setStroke(); shape.lineWidth = 2; shape.stroke() }
        } else {
            NSColor.gray.setFill()
            NSBezierPath(rect: NSRect(x: 55, y: 107, width: 8, height: 2)).fill()
        }
        if let resetLabel {
            drawGlyph(resetLabel, in: NSRect(x: 76, y: 96, width: 42, height: 23),
                      size: 14, color: .lightGray)
        }

        let meters: [(value: Double?, shown: Bool, slot: Int, color: NSColor)] = [
            (cpu, showCPU, 0, .systemTeal),
            (gpu, showGPU, 1, .systemGreen),
        ]
        for meter in meters {
            guard meter.shown else { continue }
            let rect = Self.meterRect(slot: meter.slot)
            guard let value = meter.value else { drawUnavailable(in: rect); continue }
            meter.color.setFill()
            let fillHeight = rect.height * min(1, max(0, value))
            guard fillHeight > 0 else { continue }
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY,
                width: rect.width, height: fillHeight), xRadius: 3, yRadius: 3).fill()
        }

        // 额度轨（5 小时 + 周）。画法是标准 bullet graph：
        //
        //   填充长度 = 已用百分比   ← 「用量」这个量本身，能直接读
        //   竖刻度   = 时间已过百分比 ← 同一量纲上的参照
        //
        // 于是「消耗繁忙度」不用另设一个指标表达，直接看刻度落在填充的哪一侧：
        // 刻度在填充左边 = 用掉的比时间多 = 烧得比线性快。领先超过 5 个百分点
        // 整条轨转琥珀色。
        //
        // 额度轨在底部横向填充，与右上竖向负载柱分区。
        for (index, rail) in rails.enumerated() {
            let rect = Self.railRect(index)
            let used = min(1, max(0, rail.used))
            let burning = rail.elapsed.map { used > $0 + 0.05 } ?? false
            let fill = burning
                ? NSColor.systemOrange
                : NSColor(calibratedWhite: 0.92, alpha: 1)
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY,
                                             width: rect.width * used, height: rect.height),
                         xRadius: 1.5, yRadius: 1.5).fill()
            // 刻度画在填充之上，并上下各伸出 2pt，小尺寸下才看得出是「标记」而不是
            // 又一段填充。宽度取 3pt：2pt 在 43pt 下只有 0.6px。
            if let elapsed = rail.elapsed {
                let x = rect.minX + rect.width * min(1, max(0, elapsed)) - 1.5
                NSColor(calibratedWhite: 1, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY - 2,
                                                 width: 3, height: rect.height + 4),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let dock = DockView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    let sampler = SystemSampler()
    let network = NetworkMonitor()
    let queue = OperationQueue()
    var timers: [Timer] = []
    var observers: [NSObjectProtocol] = []
    var window: NSWindow!
    let details = DetailsView()
    var config = Config.default
    var settings: SettingsWindowController!
    /// 最近一次系统采样。详情窗口的内存与磁盘区从这里取数。
    var system = SystemReading()
    /// 额度预警的跃迁检测器。只在条件跨入时触发一次，避免每 120 秒轮询都提醒。
    let alertTracker = AlertMonitor.Tracker()
    /// 连续查询失败次数。成功一次即清零——「连续」的含义就是不能被中间的成功打断。
    var failureStreak = 0
    var quota: Quota?
    var updated: Date?
    var errorText: String?
    var sleeping = false
    var loading = false
    var lastDockState = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        queue.maxConcurrentOperationCount = 1
        // 注册域是易失的，每次启动都要重注册，再叠加用户已存的持久值
        Config.registerDefaults()
        config = Config.load()
        // 诊断通道：仅在 MP_SAMPLE_LOG 指定时逐次采样落盘
        openSampleLog()
        // 启动即写一条：既确认诊断通道真的通了，也在分析时给出「进程从何时开始存在」
        // 这个基准——否则 CSV 里一段空白无法区分「没记录」和「真没发生」。
        log(String(format: "启动 pid=%d 系统指标 %.0fs / 额度 %.0fs / 布局=%@",
                  ProcessInfo.processInfo.processIdentifier,
                  config.systemInterval, config.quotaInterval,
                  Bundle.main.bundleIdentifier ?? "无 bundle id"))
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), appItem = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "退出 Monster Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = submenu; menu.addItem(appItem); NSApp.mainMenu = menu
        NSApp.dockTile.contentView = dock
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        // 内容高度由 fitWindow 按实际内容算出，这里的初值只影响首帧闪现
        window.title = "Monster Pulse"; window.isReleasedWhenClosed = false
        window.contentView?.addSubview(details)
        let button = NSButton(title: "刷新额度", target: self, action: #selector(refresh))
        button.frame = NSRect(x: 22, y: 14, width: 110, height: 32)
        window.contentView?.addSubview(button)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log("willSleep 触发：停表 \(self.timers.count) 个、取消在途查询 \(self.queue.operationCount) 个")
            self.network.stop()
            self.sleeping = true; self.timers.forEach { $0.invalidate() }; self.queue.cancelAllOperations()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // 先探针再 reset：这里要回答的是「reset() 到底有没有必要」。
            // reset() 的注释写着「否则跨越睡眠的那段会被算成一个巨大的速率」，
            // 那是推断。probeBaseline() 把「假设不 reset」的数字取出来，让结论
            // 能指回一次真实执行——参见 AGENTS.md 验证纪律第 9 条。
            if let p = self.sampler.probeBaseline() {
                let cpu = p.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "无"
                let readBps = p.uptimeElapsed > 0
                    ? String(format: "%.0f MB/s", Double(p.pageInsDelta) * 4096 / p.uptimeElapsed / 1_048_576)
                    : "除零"
                self.log(String(format: "didWake 触发：距上次采样 wall %.1fs / uptime %.1fs",
                                p.wallElapsed, p.uptimeElapsed))
                self.log("  若不 reset：CPU \(cpu)、磁盘读 \(readBps)（pageins +\(p.pageInsDelta)）")
                self.log("  uptime 是否跨睡眠增长：" + Self.uptimeVerdict(p.uptimeElapsed, p.wallElapsed))
            } else {
                self.log("didWake 触发：无上次采样基准可探（首次采样前？）")
            }
            self.sleeping = false; self.sampler.reset(); self.startTimers(); self.tick(); self.refresh()
        })
        startTimers(); tick(); refresh()
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func startTimers() {
        timers.forEach { $0.invalidate() }
        let system = Timer(timeInterval: config.systemInterval, repeats: true) { [weak self] _ in self?.tick() }
        system.tolerance = config.systemTolerance
        let codex = Timer(timeInterval: config.quotaInterval, repeats: true) { [weak self] _ in self?.refresh() }
        codex.tolerance = config.quotaTolerance
        timers = [system, codex]
        timers.forEach { RunLoop.main.add($0, forMode: .common) }
    }

    /// 配置变更后的统一处理：重启定时器让新间隔立即生效，
    /// 并刷新展示（CPU/GPU 可能被隐藏）。
    func configChanged() {
        startTimers()
        network.poll(proxy: config.effectiveProxy) { [weak self] in self?.render() }
        render()
        evaluateAlerts(afterConfigChange: true)
    }

    /// 判定并发出额度预警。数据每次查询完成后调用一次。
    ///
    /// 提醒方式是 Dock 图标跳动（`requestUserAttention`）：不需要通知授权、
    /// 不受 ad-hoc 签名限制，实测可用。为什么不用系统横幅通知见 Alerts.swift 顶部说明。
    ///
    /// 每次只对「新跨入」的预警叫一次，跳动本身由系统决定节奏；
    /// 文案不直接展示（系统横幅才有文案），所以 Alert 的 title/body 仅用于
    /// 日志与测试断言——这里如实说明，不假装用户能看到文字。
    ///
    /// - Parameter afterConfigChange: 用户刚改过预警配置。此时若是「打开」状态，
    ///   先把当前条件记为已知再判定，否则条件通常还成立着，一开设置就会弹一次。
    func evaluateAlerts(afterConfigChange: Bool = false) {
        guard config.alertsEnabled else { return }
        let windows = (quota?.windows ?? []).map {
            AlertMonitor.Window(minutes: $0.minutes, remaining: $0.remaining, resetsAt: $0.resetsAt)
        }
        let diskReadMBs = system.diskReadBytesPerSecond.map { $0 / 1_048_576 }
        if afterConfigChange {
            alertTracker.suppress(windows: windows, failureStreak: failureStreak,
                                  diskReadMBs: diskReadMBs, config: config)
        }
        let alerts = alertTracker.update(windows: windows, failureStreak: failureStreak,
                                         diskReadMBs: diskReadMBs, config: config)
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            FileHandle.standardError.write(
                "ALERT [\(alert.key)] \(alert.title)：\(alert.body)\n".data(using: .utf8)!)
        }
        // 一次只请求一次跳动：多条预警同时出现时，连续跳动没有额外信息量
        NSApp.requestUserAttention(.informationalRequest)
    }
    func tick() {
        guard !sleeping else { return }
        network.poll(proxy: config.effectiveProxy) { [weak self] in self?.render() }
        let data = sampler.sample()
        dock.cpu = data.cpu; dock.gpu = data.gpu?.deviceUtilization
        system = data
        logSample(data)
        // 额度轨：每条窗口一条，按 5 小时 → 周的顺序。用量与时间进度都来自
        // 同一次额度查询，画法见 DockView.draw 里的 bullet graph 注释。
        // 参考线随时间缓慢右移：300 分钟窗口下每 5 秒约 0.28%，在 90pt 宽的
        // 条上是 0.25pt，肉眼不可见，所以不需要动画定时器推进它。
        dock.rails = (quota?.windows ?? []).map { window in
            DockView.Rail(
                used: window.used / 100,
                elapsed: (window.resetsAt.flatMap { reset in
                    window.minutes.map { QuotaFormat.windowProgress(resetsAt: reset, windowMinutes: $0) }
                }) ?? nil)
        }
        render()
    }

    private static let processStart = Date()

        /// 判断 `systemUptime` 有没有跟上墙钟。
        ///
        /// 只能看**比值**。第一版判据写的是「uptime 动了 1 秒就算增长」，
        /// 结果实测 64.5s vs 1170.7s（5.5%）也报了「是」——判据写成绝对值就
        /// 必然误判。凡是「有没有跟上」这类判断，先想清楚量纲。
        ///
        /// 实测两次（2026-10-07，Clamshell Sleep）：
        /// 776s 墙钟 → 181.7s uptime（23%）；1170.7s → 64.5s（5.5%）。
        /// 结论：只在 CPU 真正运行时推进，用它当时间分母会严重偏小。
        static func uptimeVerdict(_ uptime: TimeInterval, _ wall: TimeInterval) -> String {
            guard wall > 10 else { return "睡眠时间过短，不判定" }
            let ratio = uptime / wall
            let verdict = ratio > 0.8 ? "是（基本跟上）"
                : ratio > 0.5 ? "部分（\(Int(ratio * 100))%）"
                : "否（仅 \(Int(ratio * 100))%，用作时间分母会严重偏小）"
            return "\(verdict)，uptime \(String(format: "%.1f", uptime))s / wall \(String(format: "%.1f", wall))s"
        }
        private func log(_ message: String) {
            let elapsed = Date().timeIntervalSince(Self.processStart)
            FileHandle.standardError.write("MP [+\(String(format: "%.1f", elapsed))s] \(message)\n".data(using: .utf8)!)
            // 同时写 sidecar：从 Dock / 登录项启动的进程 stderr 接不到，
            // 只写 stderr 会把 willSleep/didWake 这类证据全丢掉。
            guard let path = ProcessInfo.processInfo.environment["MP_SAMPLE_LOG"] else { return }
            let line = "EVENT +\(String(format: "%.1f", elapsed))s \(message)\n"
            let url = URL(fileURLWithPath: path + ".events")
            // FileHandle(forWritingTo:) 只能打开**已存在**的文件，文件不存在时抛错。
            // 之前没先创建，异常被 try? 吞掉，结果 events 一个字节都没有——
            // 而那正是 willSleep/didWake 唯一的证据来源，丢了就等于没测。
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                NSLog("MP sidecar 打开失败，事件将丢失: %@", url.path)
            }
        }

    /// 逐次采样落盘，供事后分析趋势。
    ///
    /// 只在 MP_SAMPLE_LOG 指定文件时启用（默认关闭）：这是排查用的诊断通道，
    /// 正常运行不该持续写盘——每 5 秒一次写入是真实开销，且日志无上限。
    /// 写文件用 append 且不加锁：采样全部发生在主线程，不存在并发写同一句柄。
    private var sampleLogHandle: FileHandle?

    func openSampleLog() {
        guard let path = ProcessInfo.processInfo.environment["MP_SAMPLE_LOG"] else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            log("sample log 打开失败：\(path)"); return
        }
        handle.seekToEndOfFile()
        handle.write(Self.sampleLogHeader.data(using: .utf8)!)
        sampleLogHandle = handle
        log("sample log → \(path)")
    }

    private static let sampleLogHeader = "t,cpu,memfrac,compressed,read_bps,write_bps,swap\n"

    private func logSample(_ r: SystemReading) {
        guard let handle = sampleLogHandle else { return }
        func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
        let line = [
            String(format: "%.2f", ProcessInfo.processInfo.systemUptime),
            f(r.cpu), f(r.memoryFraction), f(r.compressedBytes),
            f(r.diskReadBytesPerSecond), f(r.diskWriteBytesPerSecond), f(r.swapUsedBytes),
        ].joined(separator: ",") + "\n"
        handle.write(line.data(using: .utf8)!)
    }

    @objc func openSettings() {
        // 懒加载：设置面板有 12 个控件，用户不开设置时建它纯属浪费内存。
        // 窗口本身常驻内存没意义——不进这个分支就一个控件都不创建。
        if settings == nil {
            settings = SettingsWindowController(config: config) { [weak self] updated in
                self?.config = updated
                self?.configChanged()
            }
        }
        settings.show()
    }
    @objc func refresh() {
        guard !loading && !sleeping else { return }
        loading = true; render()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            let result = Result { try CodexReader.read(proxy: self?.config.proxyURL,
                                                 cancelled: { operation?.isCancelled ?? true }) }
            DispatchQueue.main.async {
                guard let self else { return }; self.loading = false
                switch result {
                case .success(let value):
                    self.quota = value; self.updated = Date(); self.errorText = nil
                    self.failureStreak = 0
                case .failure(let error):
                    self.errorText = error.localizedDescription
                    self.failureStreak += 1
                }
                self.render()
                self.evaluateAlerts()
            }
        }
        queue.addOperation(operation)
    }
    func render() {
        dock.remaining = quota?.windows.first?.remaining
        dock.country = network.exit?.country
        dock.proxyEnabled = network.probeProxyEnabled
        dock.resetLabel = NetworkStatus.resetLabel(quota?.windows.first?.resetsAt)
        // stale 的含义是「有快照但已过期」，所以必须先有数据。
        // 之前只要有 errorText 就是 stale，首次查询失败（根本没有快照）也会
        // 被标成过期，详情窗口与 Dock 菜单都靠各自再判一次 quotaAvailable
        // 才没出错——这类补丁容易漏，改成在源头就不成立。
        let hasData = quota != nil
        dock.stale = hasData && (errorText != nil
                                  || (updated.map { Date().timeIntervalSince($0) > 300 } ?? false))
        dock.showCPU = config.showCPU
        dock.showGPU = config.showGPU
        // 开关必须计入状态串：否则用户关掉 CPU 后图标内容变了却不会重绘
        let railsSignature = dock.rails.map { String(format: "%.3f/%.3f", $0.used, $0.elapsed ?? -1) }
            .joined(separator: ",")
        let dockState = "\(dock.remaining ?? -1):\(dock.stale):\(config.showCPU):\(config.showGPU):"
            + "\(Int((dock.cpu ?? -1) * 100)):\(Int((dock.gpu ?? -1) * 100)):\(railsSignature):\(dock.country ?? "?"):\(String(describing: dock.proxyEnabled)):\(dock.resetLabel ?? "-")"
        if dockState != lastDockState { NSApp.dockTile.display(); lastDockState = dockState }
        details.update(
            windows: (quota?.windows ?? []).map { value in
                (title: QuotaFormat.windowTitle(minutes: value.minutes),
                 used: Int(value.used.rounded()),
                 remaining: value.remaining,
                 reset: value.resetsAt.map { QuotaFormat.countdown(to: $0) })
            },
            quotaAvailable: quota != nil,
            cpu: config.showCPU ? dock.cpu : nil,
            reading: system,
            showCPU: config.showCPU, showMemory: config.showMemory, showGPU: config.showGPU,
            updated: updated, loading: loading, errorText: errorText, stale: dock.stale)
        fitWindow()
    }
    // 窗口按内容高度调整。styleMask 不含 .resizable，用户无法手动改尺寸，
    // 因此每次 render 重设 contentSize 不会和用户操作打架。
    func fitWindow() {
        let width: CGFloat = 460
        let inset: CGFloat = 22
        let bottomBar: CGFloat = 56
        let content = details.preferredHeight
        details.frame = NSRect(x: inset, y: bottomBar, width: width - inset * 2, height: content)
        let target = NSSize(width: width, height: content + inset * 2 + bottomBar)
        if window.contentView?.frame.size != target { window.setContentSize(target) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }

    // MARK: - Dock 菜单（右键 Dock 图标）
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        // 菜单仍显示内存（用户偶尔要查），但 DockView 不再持有它——
        // 数据直接从系统采样拿，不经过图标视图转一手。
        let menu = Self.buildDockMenu(target: self, quota: quota, stale: dock.stale,
                           loading: loading, errorText: errorText,
                           cpu: dock.cpu, gpu: dock.gpu,
                           memory: system.memoryFraction,
                           showCPU: config.showCPU, showGPU: config.showGPU,
                           showMemory: config.showMemory)
        let proxy = network.proxyEnabled.map { $0 ? "开启" : "关闭" } ?? "未知"
        let name = network.exit.flatMap { Locale(identifier: "zh_CN").localizedString(forRegionCode: $0.country) }
        let country = name ?? "未知"
        let lines = ["应用出口（\(network.routeLabel)）：\(country)",
                     "出口 IP：\(network.exit?.ip ?? "未知")",
                     "系统代理：\(proxy)（不代表全部流量）"]
        for (index, line) in lines.enumerated() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.insertItem(item, at: index)
        }
        return menu
    }

    /// 构造 Dock 菜单。抽成不依赖 `NSApplication` 实例的静态函数，
    /// 这样菜单结构可以脱离 Dock 单独验证——Dock 菜单只能在真实 Dock 上
    /// 右键才弹得出来，没法注入，但「有哪些项、哪些被禁用、文案是否如实」
    /// 是可以断言的。
    static func buildDockMenu(target: AnyObject, quota: Quota?, stale: Bool, loading: Bool,
                              errorText: String?, cpu: Double?, gpu: Double?, memory: Double?,
                              showCPU: Bool = true, showGPU: Bool = true, showMemory: Bool = true,
                              now: Date = Date()) -> NSMenu {
        // 两个来自官方文档的硬约束，不照做菜单就不工作：
        // 1. Dock 菜单的 target/action 不由系统代为分发，文档要求选中项后
        //    「invoke NSApp sendAction(_:to:from:)」——所以每个 action 方法
        //    自己再转发一次，不能只写 target/action 等系统调。
        // 2. NSMenuItem.isEnabled 在所属菜单 autoenablesItems 为真时完全无效
        //    （文档原文：no effect unless ... setAutoenablesItems:NO）。默认
        //    就是自动使能，所以必须显式关掉，否则状态展示项会变成可点击。
        let menu = NSMenu()
        menu.autoenablesItems = false
        // 每次显示都重建：菜单只在即将弹出时构建，状态必然是当下的，
        // 不会因为构建时机早于数据更新而显示过期内容。
        func info(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: title, attributes: [.font: NSFont.systemFont(ofSize: 11)])
            return item
        }
        func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = target
            item.isEnabled = enabled
            return item
        }

        // 状态区：与详情窗口共用同一套取数和文案格式化
        if let quota, !quota.windows.isEmpty {
            for value in quota.windows {
                menu.addItem(info("\(QuotaFormat.windowTitle(minutes: value.minutes))　剩余 \(value.remaining)%"))
                if let reset = value.resetsAt.map({ QuotaFormat.countdown(to: $0, now: now) }) {
                    menu.addItem(info("　重置 \(reset)"))
                }
            }
            // 与详情窗口一致：没有快照时不说「旧数据」
            if stale { menu.addItem(info("旧数据，仅供参考")) }
        } else {
            menu.addItem(info(loading ? "正在查询额度…" : "暂无额度数据"))
            if let errorText { menu.addItem(info(errorText)) }
        }
        menu.addItem(.separator())
        // 与图标和详情窗口保持一致：配置关掉的指标不出现在菜单里
        if showCPU {
            menu.addItem(info("CPU　\(cpu.map { String(format: "%.0f%%", $0 * 100) } ?? "采样中")"))
        }
        if showGPU {
            menu.addItem(info("GPU　\(gpu.map { String(format: "%.0f%%", $0 * 100) } ?? "不可用")"))
        }
        if showMemory {
            menu.addItem(info("内存　\(memory.map { String(format: "%.0f%%", $0 * 100) } ?? "不可用")"))
        }
        menu.addItem(.separator())
        // 查询进行中禁用刷新，而不是让点了没反应——对应 refresh() 里的
        // !loading 守卫，把「不会叠加正在执行的查询」如实暴露给用户
        menu.addItem(action(loading ? "正在查询…" : "立即刷新额度",
                            #selector(AppDelegate.dockMenuRefresh), enabled: !loading))
        menu.addItem(action("打开详情", #selector(AppDelegate.dockMenuShowDetails)))
        menu.addItem(action("设置…", #selector(AppDelegate.dockMenuSettings)))
        menu.addItem(.separator())
        menu.addItem(action("退出 Monster Pulse", #selector(AppDelegate.dockMenuQuit)))
        return menu
    }

    // Dock 菜单的 action 不由系统分发，需自己转成 sendAction（官方文档要求）。
    // 只在方法签名能对上时用 sendAction：
    //   · refresh() 零参，sendAction 正好能调用。
    //   · applicationShouldHandleReopen(_:hasVisibleWindows:) 是两个参数的协议
    //     方法，sendAction 无法正确调用它（第一个坑），所以直接做该做的事。
    @objc private func dockMenuRefresh(_ sender: Any?) {
        NSApp.sendAction(#selector(refresh), to: self, from: nil)
    }
    @objc private func dockMenuShowDetails(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func dockMenuQuit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
    @objc private func dockMenuSettings(_ sender: Any?) {
        NSApp.sendAction(#selector(openSettings), to: self, from: nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        timers.forEach { $0.invalidate() }
        network.stop()
        queue.cancelAllOperations(); queue.waitUntilAllOperationsAreFinished()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// NSApplication 默认不处理 SIGTERM/SIGINT：进程被信号直接终止，
// applicationWillTerminate 里的 cancelAllOperations + waitUntilAllOperationsAreFinished
// 根本不会执行，查询进行中退出会留下孤儿子进程（kill、进程管理器、CI 超时清理
// 走的都是这条路，只有 Command-Q 菜单项才会走正常退出）。
// 这里接管这两个信号并转发给 terminate，让所有退出路径共用同一套清理逻辑。
// 用 DispatchSource 而不是裸 signal handler：terminate 会碰 AppKit，不能在信号上下文里调。
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { application.terminate(nil) }
    source.resume()
    signalSources.append(source)   // 必须保留引用，释放后监听失效
}
defer { signalSources.forEach { $0.cancel() } }

application.run()
