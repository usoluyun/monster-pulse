import AppKit
import Darwin

// A broken child-process pipe must become an error rather than terminate the app.
signal(SIGPIPE, SIG_IGN)

func verify() throws {
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
    guard let cpu = system.cpu, let memory = system.memory,
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
                                        loading: false, errorText: nil, cpu: 0.42, memory: 0.61,
                                        now: menuNow),
              "正常状态",
              enabledTitles: ["立即刷新额度", "打开详情", "退出 Monster Pulse"],
              disabledTitles: ["5 小时窗口　剩余 92%", "CPU　42%", "内存　61%"])
    // 查询进行中必须禁用刷新：对应 refresh() 的 !loading 守卫，
    // 避免用户连点叠加查询
    checkMenu(AppDelegate.buildDockMenu(target: menuTarget, quota: demoQuota, stale: false,
                                        loading: true, errorText: nil, cpu: 0.42, memory: 0.61,
                                        now: menuNow),
              "加载中",
              enabledTitles: ["打开详情", "退出 Monster Pulse"],
              disabledTitles: ["正在查询…"])
    // 无数据时不能出现「旧数据，仅供参考」——没有快照就说旧数据不成立
    let noDataTitles = AppDelegate.buildDockMenu(target: menuTarget, quota: nil, stale: true,
                                                 loading: false, errorText: "查询失败",
                                                 cpu: nil, memory: nil, now: menuNow)
        .items.map(\.title)
    for bogus in ["旧数据，仅供参考", "5 小时窗口　剩余 92%"] where noDataTitles.contains(bogus) {
        failures.append("无数据状态不应出现「\(bogus)」")
    }

    // Config 的越界夹取与持久化。直接往 UserDefaults 写脏值再 load()，
    // 验证「配置文件被手改或来自旧版本」时不会让定时器行为失控。
    let defaults = UserDefaults.standard
    let domain = Bundle.main.bundleIdentifier ?? "local.monsterpulse.selftest"
    func withConfigDomain<T>(_ body: () -> T) -> T {
        defaults.removePersistentDomain(forName: domain)
        // register 的注册域挂在 app 域上，这里直接改写同一批 key
        return body()
    }
    withConfigDomain {
        defaults.set(0.0, forKey: "systemSampleInterval")       // 越下界
        defaults.set(9999.0, forKey: "quotaRefreshInterval")    // 越上界
        defaults.set(Double.nan, forKey: "systemSampleInterval")
        let clamped = Config.load()
        if clamped.systemInterval != Config.defaultSystemInterval {
            failures.append("Config.load 越界 systemInterval 应回退默认，得到 \(clamped.systemInterval)")
        }
        if clamped.quotaInterval != Config.defaultQuotaInterval {
            failures.append("Config.load 越界 quotaInterval 应回退默认，得到 \(clamped.quotaInterval)")
        }
        // 合法区间内的值必须被保留，不能被误夹
        defaults.set(7.0, forKey: "systemSampleInterval")
        defaults.set(45.0, forKey: "quotaRefreshInterval")
        let kept = Config.load()
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
                                               failureStreak: 0, config: alertConfig, now: alertNow)),
                 [], "正常状态不应有预警")
    // 剩余 15% 低于默认阈值 20% → 触发；20% 恰好等于阈值不算越线（阈值向上取整）
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 15, resetIn: 3600 * 3),
                                               failureStreak: 0, config: alertConfig, now: alertNow)),
                 ["low-quota"], "剩余 15% 应触发额度预警")
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 20, resetIn: 3600 * 3),
                                               failureStreak: 0, config: alertConfig, now: alertNow)),
                 [], "剩余 20% 等于阈值不应触发")
    // 重置临近：默认提前 30 分钟
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 60 * 20),
                                               failureStreak: 0, config: alertConfig, now: alertNow)),
                 ["reset-soon-0"], "20 分钟后重置应触发")
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 60 * 40),
                                               failureStreak: 0, config: alertConfig, now: alertNow)),
                 [], "40 分钟后重置不应触发")
    // 连续失败默认 3 次：2 次不报、3 次才报
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 3600 * 3),
                                               failureStreak: 2, config: alertConfig, now: alertNow)),
                 [], "连续失败 2 次不应触发")
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 92, resetIn: 3600 * 3),
                                               failureStreak: 3, config: alertConfig, now: alertNow)),
                 ["query-failed"], "连续失败 3 次应触发")
    // 关闭预警后一律不触发
    var muted = Config.default; muted.setAlertsEnabled(false)
    expectAlerts(keys(AlertMonitor.activeAlerts(windows: alertWindows(remaining: 1, resetIn: 60),
                                               failureStreak: 99, config: muted, now: alertNow)),
                 [], "关闭预警后不应有任何预警")

    // 跃迁去重：同一条件持续成立只触发一次，条件消失后再次成立才重新触发。
    let tracker = AlertMonitor.Tracker()
    let low = alertWindows(remaining: 15, resetIn: 3600 * 3)
    let normal = alertWindows(remaining: 92, resetIn: 3600 * 3)
    let firstFire = tracker.update(windows: low, failureStreak: 0, config: alertConfig, now: alertNow)
    if firstFire.map(\.key) != ["low-quota"] {
        failures.append("Tracker 首次越线应产生 low-quota，得到 \(firstFire.map(\.key))")
    }
    for round in 1...5 {
        let repeatFire = tracker.update(windows: low, failureStreak: 0, config: alertConfig,
                                        now: alertNow.addingTimeInterval(TimeInterval(round * 120)))
        if !repeatFire.isEmpty {
            failures.append("Tracker 在条件持续成立时第 \(round) 轮重复触发了 \(repeatFire.map(\.key))")
            break
        }
    }
    // 条件消失后清空，再次越线应重新触发
    _ = tracker.update(windows: normal, failureStreak: 0, config: alertConfig,
                       now: alertNow.addingTimeInterval(720))
    let reFire = tracker.update(windows: low, failureStreak: 0, config: alertConfig,
                               now: alertNow.addingTimeInterval(840))
    if reFire.map(\.key) != ["low-quota"] {
        failures.append("Tracker 在条件消失后再次越线应重新触发，得到 \(reFire.map(\.key))")
    }
    // suppress()：关掉再打开预警时，条件通常还成立着，不应立刻再弹一次。
    // 这与 reset() 语义相反——reset() 清空记录，下次会把当前条件当成新跃迁。
    tracker.reset()
    let reFireAfterReset = tracker.update(windows: low, failureStreak: 0, config: alertConfig,
                                          now: alertNow.addingTimeInterval(960))
    if reFireAfterReset.map(\.key) != ["low-quota"] {
        failures.append("Tracker.reset() 后应把当前条件当作新跃迁，得到 \(reFireAfterReset.map(\.key))")
    }
    tracker.suppress(windows: low, failureStreak: 0, config: alertConfig, now: alertNow)
    let afterSuppress = tracker.update(windows: low, failureStreak: 0, config: alertConfig,
                                       now: alertNow.addingTimeInterval(1080))
    if !afterSuppress.isEmpty {
        failures.append("Tracker.suppress() 后不应立即触发，得到 \(afterSuppress.map(\.key))")
    }
    // suppress 之后条件再次成立仍要能触发（说明 suppress 没有把记录写死）
    _ = tracker.update(windows: normal, failureStreak: 0, config: alertConfig,
                       now: alertNow.addingTimeInterval(1200))
    let afterSuppressRefire = tracker.update(windows: low, failureStreak: 0, config: alertConfig,
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

    if !failures.isEmpty {
        for line in failures { fputs("FAIL  \(line)\n", stderr) }
        throw ReadError.message("自检失败 \(failures.count) 项")
    }
    print("PASS: quota parsing, missing/invalid/other buckets, CPU and memory sampling, window title and countdown formatting, dock menu structure, config clamping, quota alerts")
}

if CommandLine.arguments.contains("--self-test") {
    do { try verify(); exit(0) } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--draw-bench") {
    // 量化单次 draw 成本，用来定低帧率动效的帧率预算。
    // Dock 图标走 dockTile 离屏渲染，没有 GPU 合成可借力——每帧都要 CPU 重画，
    // 所以单帧成本 × 帧率就是动效的额外 CPU 预算。
    let view = DockView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    view.remaining = 92; view.cpu = 0.42; view.memory = 0.61
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
    view.remaining = args.count > 1 ? Int(args[1]) : 92
    view.cpu = args.count > 2 ? Double(args[2]) : 0.42
    view.memory = args.count > 3 ? Double(args[3]) : 0.61
    view.stale = args.count > 4 ? args[4] == "stale" : false
    // 第 6 个参数可选，控制 CPU/内存条的显示，用于覆盖配置关掉指标后的图标外观。
    // 取值 both / no-cpu / no-mem / no-both。
    if args.count > 5 {
        let meters = args[5]
        view.showCPU = meters != "no-cpu" && meters != "no-both"
        view.showMemory = meters != "no-mem" && meters != "no-both"
    }
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) remaining=\(view.remaining ?? -1) cpu=\(view.cpu ?? -1) memory=\(view.memory ?? -1) stale=\(view.stale)")
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
                                                     cpu: 0.42, memory: 0.61, now: now)
    case "stale":     menu = AppDelegate.buildDockMenu(target: target, quota: demo, stale: true,
                                                     loading: false, errorText: nil,
                                                     cpu: 0.42, memory: 0.61, now: now)
    case "error":     menu = AppDelegate.buildDockMenu(target: target, quota: nil, stale: true,
                                                     loading: false,
                                                     errorText: "Codex 查询超时或进程退出；请检查 CLI 登录状态和网络",
                                                     cpu: 0.42, memory: 0.61, now: now)
    case "loading":   menu = AppDelegate.buildDockMenu(target: target, quota: demo, stale: false,
                                                     loading: true, errorText: nil,
                                                     cpu: 0.42, memory: 0.61, now: now)
    default:          menu = AppDelegate.buildDockMenu(target: target, quota: demo, stale: false,
                                                     loading: false, errorText: nil,
                                                     cpu: 0.42, memory: 0.61, now: now)
    }
    defer { _ = target }
    print("state=\(state)")
    for item in menu.items {
        let title = item.isSeparatorItem ? "--" : item.title
        print("\(item.isEnabled ? "enabled" : "disabled")\t\(title)")
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
    switch state {
    case "no-data", "no-data-no-meters":
        details.update(windows: [], quotaAvailable: false, cpu: nil, memory: nil,
                       showCPU: showCPU, showMemory: showMemory,
                       updated: nil, loading: false, errorText: nil, stale: false)
    case "stale":
        details.update(windows: windows, quotaAvailable: true, cpu: 0.42, memory: 0.61,
                       showCPU: showCPU, showMemory: showMemory,
                       updated: now.addingTimeInterval(-600), loading: false, errorText: nil, stale: true)
    case "error":
        details.update(windows: [], quotaAvailable: false, cpu: 0.42, memory: 0.61,
                       showCPU: showCPU, showMemory: showMemory,
                       updated: nil, loading: false,
                       errorText: "Codex 查询超时或进程退出；请检查 CLI 登录状态和网络", stale: true)
    case "loading":
        details.update(windows: windows, quotaAvailable: true, cpu: 0.42, memory: 0.61,
                       showCPU: showCPU, showMemory: showMemory,
                       updated: now, loading: true, errorText: nil, stale: false)
    default:
        details.update(windows: windows, quotaAvailable: true, cpu: 0.42, memory: 0.61,
                       showCPU: showCPU, showMemory: showMemory,
                       updated: now, loading: false, errorText: nil, stale: false)
    }

    let content = details.preferredHeight
    let total = NSSize(width: width, height: content + inset * 2 + bottomBar)
    // 容器模拟真实窗口的 contentView，这样 details 的 frame 与线上一致
    let container = NSView(frame: NSRect(origin: .zero, size: total))
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
        let quota = try CodexReader.read()
        for window in quota.windows {
            print("Codex: remaining=\(window.remaining)% windowMinutes=\(window.minutes.map(String.init) ?? "unknown") reset=\(window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
        }
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

final class DockView: NSView {
    var remaining: Int?
    var cpu: Double?
    var memory: Double?
    var stale = false
    var showCPU = true
    var showMemory = true

    // Dock 图标走 dockTile 离屏渲染，没有 GPU 合成可借力，每次 display 都要 CPU 重画。
    // 静态部分（背景、进度条底槽）与数字文字的排版是主要开销——后者每次都要重跑
    // 段落布局。预渲染成位图后重绘只剩位图拷贝，为后续低帧率动效腾出预算。
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    private var backdrop: NSImage?
    private var backdropStale = false
    private var backdropSize: CGSize = .zero
    private var glyphs: [String: NSImage] = [:]

    // 数字只在变化时重排，key 覆盖「文本+字号+颜色」，取值域有界（百分比 0…100）
    private func drawGlyph(_ text: String, at y: CGFloat, size: CGFloat, color: NSColor) {
        let key = "\(text)|\(size)|\(color.description)"
        let image: NSImage
        if let hit = glyphs[key] {
            image = hit
        } else {
            image = NSImage(size: NSSize(width: 120, height: size + 9), flipped: false) { rect in
                (text as NSString).draw(in: rect, withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: color, .paragraphStyle: DockView.paragraph])
                return true
            }
            glyphs[key] = image
        }
        image.draw(in: NSRect(x: 4, y: y, width: 120, height: size + 9))
    }

    private func makeBackdrop() -> NSImage {
        NSImage(size: bounds.size, flipped: false) { rect in
            NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), xRadius: 24, yRadius: 24).fill()
            NSColor.darkGray.setFill()
            for index in 0..<2 {
                let bar = NSRect(x: 19, y: 32 - index * 13, width: 90, height: 7)
                NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if backdrop == nil || backdropStale != stale || backdropSize != bounds.size {
            backdrop = makeBackdrop()
            backdropStale = stale
            backdropSize = bounds.size
        }
        backdrop?.draw(in: bounds)

        drawGlyph(stale ? "CODEX · OLD" : "CODEX", at: 91, size: 11, color: .lightGray)
        drawGlyph(remaining.map { "\($0)%" } ?? "—", at: 48, size: 32,
                  color: stale ? .systemOrange : .white)

        // 进度条填充随 cpu/memory 每 5 秒变，形状简单，保持实时绘制。
        // 每个指标占固定槽位（CPU 上、内存下），关闭某项时另一项不移动，
        // 避免用户切开关时图标里另一根条跳位。
        let meters: [(value: Double?, shown: Bool, slot: Int, color: NSColor)] = [
            (cpu, showCPU, 0, .systemTeal),
            (memory, showMemory, 1, .systemPurple),
        ]
        for meter in meters {
            guard meter.shown, let value = meter.value else { continue }
            let rect = NSRect(x: 19, y: 32 - meter.slot * 13, width: 90, height: 7)
            meter.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY,
                width: rect.width * value, height: 7), xRadius: 3, yRadius: 3).fill()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let dock = DockView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    let sampler = SystemSampler()
    let queue = OperationQueue()
    var timers: [Timer] = []
    var observers: [NSObjectProtocol] = []
    var window: NSWindow!
    let details = DetailsView()
    var config = Config.default
    var settings: SettingsWindowController!
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
            self?.sleeping = true; self?.timers.forEach { $0.invalidate() }; self?.queue.cancelAllOperations()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.sleeping = false; self.sampler.reset(); self.startTimers(); self.tick(); self.refresh()
        })
        startTimers(); tick(); refresh()
        settings = SettingsWindowController(config: config) { [weak self] updated in
            self?.config = updated
            self?.configChanged()
        }
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
    /// 并刷新展示（CPU/内存可能被隐藏）。
    func configChanged() {
        startTimers()
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
        if afterConfigChange { alertTracker.suppress(windows: windows, failureStreak: failureStreak, config: config) }
        let alerts = alertTracker.update(windows: windows, failureStreak: failureStreak, config: config)
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
        let data = sampler.sample(); dock.cpu = data.cpu; dock.memory = data.memory; render()
    }
    @objc func openSettings() {
        settings.show()
    }
    @objc func refresh() {
        guard !loading && !sleeping else { return }
        loading = true; render()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            let result = Result { try CodexReader.read(cancelled: { operation?.isCancelled ?? true }) }
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
        dock.stale = errorText != nil || (updated.map { Date().timeIntervalSince($0) > 300 } ?? false)
        dock.showCPU = config.showCPU
        dock.showMemory = config.showMemory
        // 开关必须计入状态串：否则用户关掉 CPU 后图标内容变了却不会重绘
        let dockState = "\(dock.remaining ?? -1):\(dock.stale):\(config.showCPU):\(config.showMemory):"
            + "\(Int((dock.cpu ?? -1) * 100)):\(Int((dock.memory ?? -1) * 100))"
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
            memory: config.showMemory ? dock.memory : nil,
            showCPU: config.showCPU, showMemory: config.showMemory,
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
        Self.buildDockMenu(target: self, quota: quota, stale: dock.stale,
                           loading: loading, errorText: errorText,
                           cpu: dock.cpu, memory: dock.memory,
                           showCPU: config.showCPU, showMemory: config.showMemory)
    }

    /// 构造 Dock 菜单。抽成不依赖 `NSApplication` 实例的静态函数，
    /// 这样菜单结构可以脱离 Dock 单独验证——Dock 菜单只能在真实 Dock 上
    /// 右键才弹得出来，没法注入，但「有哪些项、哪些被禁用、文案是否如实」
    /// 是可以断言的。
    static func buildDockMenu(target: AnyObject, quota: Quota?, stale: Bool, loading: Bool,
                              errorText: String?, cpu: Double?, memory: Double?,
                              showCPU: Bool = true, showMemory: Bool = true,
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
        timers.forEach { $0.invalidate() }; queue.cancelAllOperations(); queue.waitUntilAllOperationsAreFinished()
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
