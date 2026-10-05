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
    let sampler = SystemSampler()
    _ = sampler.sample()
    usleep(100_000)
    let system = sampler.sample()
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
        expect(DetailsView.windowTitle(minutes: minutes), expected, "windowTitle(\(minutes))")
    }
    // 90 分钟不是整小时，不能塌缩成「1 小时窗口」——窗口长度以服务返回为准
    expect(DetailsView.windowTitle(minutes: 90), "90 分钟窗口", "windowTitle(90) 非整小时")
    for missing in [nil, 0, -5] as [Int?] {
        expect(DetailsView.windowTitle(minutes: missing), "额度窗口", "windowTitle(\(String(describing: missing)))")
    }

    // 倒计时：已到期、纯分、纯小时、天+小时；整小时不能退化成「60 分后」
    let now = Date()
    for (offset, expected) in [(0.0, "已到期"), (-3600.0, "已到期"),
                               (60.0 * 30, "30 分后"), (3600.0 * 3, "3 小时后"),
                               (3600.0 * 3 + 60.0 * 12, "3 小时 12 分后"),
                               (86400.0 * 5, "5 天后"), (86400.0 * 2 + 3600.0 * 6, "2 天 6 小时后")] {
        expect(DetailsView.countdown(to: now.addingTimeInterval(offset), now: now),
               expected, "countdown(+\(Int(offset))s)")
    }

    if !failures.isEmpty {
        for line in failures { fputs("FAIL  \(line)\n", stderr) }
        throw ReadError.message("自检失败 \(failures.count) 项")
    }
    print("PASS: quota parsing, missing/invalid/other buckets, CPU and memory sampling, window title and countdown formatting")
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
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) remaining=\(view.remaining ?? -1) cpu=\(view.cpu ?? -1) memory=\(view.memory ?? -1) stale=\(view.stale)")
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
        (DetailsView.windowTitle(minutes: 300), 8, 92,
         DetailsView.countdown(to: now.addingTimeInterval(3 * 3600 + 12 * 60), now: now)),
        (DetailsView.windowTitle(minutes: 10080), 10, 90,
         DetailsView.countdown(to: now.addingTimeInterval(5 * 86400 + 15 * 3600), now: now)),
    ]
    switch state {
    case "no-data":
        details.update(windows: [], quotaAvailable: false, cpu: nil, memory: nil,
                       updated: nil, loading: false, errorText: nil, stale: false)
    case "stale":
        details.update(windows: windows, quotaAvailable: true, cpu: 0.42, memory: 0.61,
                       updated: now.addingTimeInterval(-600), loading: false, errorText: nil, stale: true)
    case "error":
        details.update(windows: [], quotaAvailable: false, cpu: 0.42, memory: 0.61,
                       updated: nil, loading: false,
                       errorText: "Codex 查询超时或进程退出；请检查 CLI 登录状态和网络", stale: true)
    case "loading":
        details.update(windows: windows, quotaAvailable: true, cpu: 0.42, memory: 0.61,
                       updated: now, loading: true, errorText: nil, stale: false)
    default:
        details.update(windows: windows, quotaAvailable: true, cpu: 0.42, memory: 0.61,
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

        // 进度条填充随 cpu/memory 每 5 秒变，形状简单，保持实时绘制
        for (index, value) in [cpu, memory].enumerated() {
            guard let value else { continue }
            let rect = NSRect(x: 19, y: 32 - index * 13, width: 90, height: 7)
            (index == 0 ? NSColor.systemTeal : NSColor.systemPurple).setFill()
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
    var quota: Quota?
    var updated: Date?
    var errorText: String?
    var sleeping = false
    var loading = false
    var lastDockState = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        queue.maxConcurrentOperationCount = 1
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), appItem = NSMenuItem(), submenu = NSMenu()
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
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func startTimers() {
        timers.forEach { $0.invalidate() }
        let system = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        system.tolerance = 1
        let codex = Timer(timeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
        codex.tolerance = 15
        timers = [system, codex]
        timers.forEach { RunLoop.main.add($0, forMode: .common) }
    }
    func tick() {
        guard !sleeping else { return }
        let data = sampler.sample(); dock.cpu = data.cpu; dock.memory = data.memory; render()
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
                case .success(let value): self.quota = value; self.updated = Date(); self.errorText = nil
                case .failure(let error): self.errorText = error.localizedDescription
                }
                self.render()
            }
        }
        queue.addOperation(operation)
    }
    func render() {
        dock.remaining = quota?.windows.first?.remaining
        dock.stale = errorText != nil || (updated.map { Date().timeIntervalSince($0) > 300 } ?? false)
        let dockState = "\(dock.remaining ?? -1):\(dock.stale):\(Int((dock.cpu ?? -1) * 100)):\(Int((dock.memory ?? -1) * 100))"
        if dockState != lastDockState { NSApp.dockTile.display(); lastDockState = dockState }
        details.update(
            windows: (quota?.windows ?? []).map { value in
                (title: DetailsView.windowTitle(minutes: value.minutes),
                 used: Int(value.used.rounded()),
                 remaining: value.remaining,
                 reset: value.resetsAt.map { DetailsView.countdown(to: $0) })
            },
            quotaAvailable: quota != nil,
            cpu: dock.cpu, memory: dock.memory,
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
