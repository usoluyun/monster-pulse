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
    print("PASS: quota parsing, missing/invalid/other buckets, CPU and memory sampling")
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
    // 用法: CodexDock --render-test <out.png> [remaining] [cpu] [memory] [stale]
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
    let details = NSTextField(wrappingLabelWithString: "")
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
        submenu.addItem(withTitle: "退出 Codex Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = submenu; menu.addItem(appItem); NSApp.mainMenu = menu
        NSApp.dockTile.contentView = dock
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Codex Dock · PoC"; window.isReleasedWhenClosed = false
        details.frame = NSRect(x: 24, y: 75, width: 412, height: 300)
        details.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        window.contentView?.addSubview(details)
        let button = NSButton(title: "刷新额度", target: self, action: #selector(refresh))
        button.frame = NSRect(x: 24, y: 24, width: 110, height: 32)
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
        var lines = ["Codex 订阅额度" ]
        if let quota {
            for (i, value) in quota.windows.enumerated() {
                let duration = value.minutes.map { "\($0) 分钟窗口" } ?? "窗口 \(i + 1)"
                lines.append("\(duration)：剩余 \(value.remaining)%")
                if let reset = value.resetsAt {
                    let minutes = max(0, Int(ceil(reset.timeIntervalSinceNow / 60)))
                    lines.append("重置：\(DateFormatter.localizedString(from: reset, dateStyle: .short, timeStyle: .short))（\(minutes) 分钟）")
                }
            }
        } else { lines.append("暂无额度数据") }
        lines.append("")
        lines.append("CPU：\(dock.cpu.map { String(format: "%.0f%%", $0 * 100) } ?? "采样中")")
        lines.append("内存估算：\(dock.memory.map { String(format: "%.0f%%", $0 * 100) } ?? "不可用")")
        if let updated { lines.append("更新：\(DateFormatter.localizedString(from: updated, dateStyle: .none, timeStyle: .medium))") }
        if loading { lines.append("正在查询…") }
        if let errorText { lines.append(errorText) }
        if dock.stale { lines.append("旧数据，仅供参考") }
        details.stringValue = lines.joined(separator: "\n")
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
