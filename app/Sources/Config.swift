import AppKit

/// 用户配置。
///
/// 默认值走 `UserDefaults.register(defaults:)` 的易失注册域——文档说明
/// 「The registration domain is volatile, so you must register the set of
/// default values each time your app launches」。所以每次启动都要重新注册，
/// 而用户的修改落在持久域里，能跨启动保留，两层各司其职。
///
/// 刻意不调用 `synchronize()`：官方文档写明「this method is unnecessary
/// and shouldn't be used」。
struct Config {
    /// 系统指标采样间隔（秒）。取值范围有限，取值域有界以便滑杆与文案一致。
    static let systemIntervalRange: ClosedRange<Double> = 1...30
    /// 额度轮询间隔（秒）。下限不低于 30，避免用户把查询打成高频。
    static let quotaIntervalRange: ClosedRange<Double> = 30...900

    static let defaultSystemInterval = 5.0
    static let defaultQuotaInterval = 120.0

    /// 预警阈值。取值范围同样有界，便于滑杆与文案一致。
    static let alertThresholdRange: ClosedRange<Double> = 5...90
    static let alertLeadRange: ClosedRange<Double> = 5...180
    static let alertStreakRange: ClosedRange<Double> = 1...10

    static let defaultAlertThreshold = 20.0
    static let defaultAlertLead = 30.0
    static let defaultAlertStreak = 3.0

    /// 磁盘读入速率预警阈值（MB/s）。跑本地大模型时权重加载会远超这个量级。
    static let diskAlertRange: ClosedRange<Double> = 20...2000
    static let defaultDiskAlert = 200.0

    private enum Key {
        static let systemInterval = "systemSampleInterval"
        static let quotaInterval = "quotaRefreshInterval"
        static let showCPU = "showCPU"
        static let showMemory = "showMemory"
        static let alertsEnabled = "alertsEnabled"
        static let alertThreshold = "alertQuotaThreshold"
        static let alertLead = "alertResetLeadMinutes"
        static let alertStreak = "alertFailureStreak"
        static let diskAlertThreshold = "diskReadAlertMBs"
        static let proxyURL = "codexProxyURL"
    }

    var systemInterval: Double
    var quotaInterval: Double
    var showCPU: Bool
    var showMemory: Bool
    var alertsEnabled: Bool
    /// 主额度窗口剩余低于此百分比即预警
    var alertQuotaThreshold: Double
    /// 重置时间在此分钟数内即预警
    var alertResetLeadMinutes: Double
    /// 连续失败达到此次数即预警
    var alertFailureStreak: Double
    /// 磁盘读入速率超过此 MB/s 即预警
    var diskAlertMBs: Double
    /// Codex 子进程使用的代理，如 http://127.0.0.1:12334。
    ///
    /// 为什么需要它：从 Dock 启动的应用不经过 shell，**不读 .zshrc**，所以
    /// 应用进程及其 spawn 出的 codex 子进程都没有 http_proxy/https_proxy。
    /// 若 codex 需要代理才能连通 API，直接从 Finder/Dock 启动就会查询超时，
    /// 而在终端跑 --probe 却正常——差别只在这里。
    ///
    /// 注意这会以明文存进 UserDefaults（本项目只代理 localhost，一般不含凭据）。
    var proxyURL: String

    static let `default` = Config(systemInterval: defaultSystemInterval,
                                  quotaInterval: defaultQuotaInterval,
                                  showCPU: true, showMemory: true,
                                  alertsEnabled: true,
                                  alertQuotaThreshold: defaultAlertThreshold,
                                  alertResetLeadMinutes: defaultAlertLead,
                                  alertFailureStreak: defaultAlertStreak,
                                  diskAlertMBs: defaultDiskAlert,
                                  proxyURL: "")

    /// 每次启动都要调用，把默认值注册进易失域。
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.systemInterval: defaultSystemInterval,
            Key.quotaInterval: defaultQuotaInterval,
            Key.showCPU: true,
            Key.showMemory: true,
            Key.alertsEnabled: true,
            Key.alertThreshold: defaultAlertThreshold,
            Key.alertLead: defaultAlertLead,
            Key.alertStreak: defaultAlertStreak,
            Key.diskAlertThreshold: defaultDiskAlert,
            Key.proxyURL: "",
        ])
    }

    static func load() -> Config {
        let d = UserDefaults.standard
        // 越界值要夹回区间：配置文件可能被手改或来自旧版本，
        // 直接拿去做 Timer 间隔或阈值会让行为不可预期
        let clamp = { (value: Double, range: ClosedRange<Double>, fallback: Double) in
            guard value.isFinite, range.contains(value) else { return fallback }
            return value
        }
        return Config(
            systemInterval: clamp(d.double(forKey: Key.systemInterval),
                                   systemIntervalRange, defaultSystemInterval),
            quotaInterval: clamp(d.double(forKey: Key.quotaInterval),
                                 quotaIntervalRange, defaultQuotaInterval),
            showCPU: d.bool(forKey: Key.showCPU),
            showMemory: d.bool(forKey: Key.showMemory),
            alertsEnabled: d.bool(forKey: Key.alertsEnabled),
            alertQuotaThreshold: clamp(d.double(forKey: Key.alertThreshold),
                                       alertThresholdRange, defaultAlertThreshold),
            alertResetLeadMinutes: clamp(d.double(forKey: Key.alertLead),
                                         alertLeadRange, defaultAlertLead),
            alertFailureStreak: clamp(d.double(forKey: Key.alertStreak),
                                      alertStreakRange, defaultAlertStreak),
            diskAlertMBs: clamp(d.double(forKey: Key.diskAlertThreshold),
                                diskAlertRange, defaultDiskAlert),
            proxyURL: d.string(forKey: Key.proxyURL) ?? "")
    }

    /// 保存单项变更。写入即生效，由调用方负责重启定时器。
    mutating func setSystemInterval(_ value: Double) {
        systemInterval = Self.systemIntervalRange.contains(value) ? value : Self.defaultSystemInterval
        UserDefaults.standard.set(systemInterval, forKey: Key.systemInterval)
    }
    mutating func setQuotaInterval(_ value: Double) {
        quotaInterval = Self.quotaIntervalRange.contains(value) ? value : Self.defaultQuotaInterval
        UserDefaults.standard.set(quotaInterval, forKey: Key.quotaInterval)
    }
    mutating func setShowCPU(_ value: Bool) {
        showCPU = value
        UserDefaults.standard.set(value, forKey: Key.showCPU)
    }
    mutating func setShowMemory(_ value: Bool) {
        showMemory = value
        UserDefaults.standard.set(value, forKey: Key.showMemory)
    }
    mutating func setAlertsEnabled(_ value: Bool) {
        alertsEnabled = value
        UserDefaults.standard.set(value, forKey: Key.alertsEnabled)
    }
    mutating func setAlertThreshold(_ value: Double) {
        alertQuotaThreshold = Self.alertThresholdRange.contains(value) ? value : Self.defaultAlertThreshold
        UserDefaults.standard.set(alertQuotaThreshold, forKey: Key.alertThreshold)
    }
    mutating func setAlertLead(_ value: Double) {
        alertResetLeadMinutes = Self.alertLeadRange.contains(value) ? value : Self.defaultAlertLead
        UserDefaults.standard.set(alertResetLeadMinutes, forKey: Key.alertLead)
    }
    mutating func setAlertStreak(_ value: Double) {
        alertFailureStreak = Self.alertStreakRange.contains(value) ? value : Self.defaultAlertStreak
        UserDefaults.standard.set(alertFailureStreak, forKey: Key.alertStreak)
    }

    mutating func setDiskAlertMBs(_ value: Double) {
        diskAlertMBs = Self.diskAlertRange.contains(value) ? value : Self.defaultDiskAlert
        UserDefaults.standard.set(diskAlertMBs, forKey: Key.diskAlertThreshold)
    }

    mutating func setProxyURL(_ raw: String) {
        proxyURL = ProxySetting.normalize(raw) ?? ""
        UserDefaults.standard.set(proxyURL, forKey: Key.proxyURL)
    }

    /// 规范化后的代理，nil 表示不设代理。查询时注入子进程环境。
    var effectiveProxy: String? { ProxySetting.normalize(proxyURL) }

    mutating func resetToDefaults() {
        self = .default
        for key in [Key.systemInterval, Key.quotaInterval, Key.showCPU, Key.showMemory,
                    Key.alertsEnabled, Key.alertThreshold, Key.alertLead, Key.alertStreak,
                    Key.diskAlertThreshold, Key.proxyURL] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// 采样间隔对应的定时器容差。沿用 PoC 的经验值（间隔的 20%），
    /// 让系统能合并唤醒，省电；下限 1 秒避免过度合并。
    var systemTolerance: TimeInterval { max(1, systemInterval * 0.2) }
    var quotaTolerance: TimeInterval { max(1, quotaInterval * 0.125) }
}


// MARK: - 设置面板

/// 设置窗口。改动即时生效（写 UserDefaults 并回调 AppDelegate），不设
/// 「确定/取消」——取消语义在这里没有意义，用户拖完滑杆就期待看到效果。
///
/// 布局用行列表而非硬编码坐标：每行声明「视图 + 高度 + 与上一行的间距」，
/// 加一项配置只需 append 一行，窗口高度由内容算出。加控件时如果改成手写
/// y 坐标，前几次改动就已经把控件挤出过边界。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private struct Row {
        let view: NSView
        let height: CGFloat
        let gapBefore: CGFloat
    }

    private static let inset: CGFloat = 24
    private static let labelWidth: CGFloat = 112
    private static let sliderWidth: CGFloat = 150
    private static let windowWidth: CGFloat = 400
    private static let bottomBar: CGFloat = 48

    private let window: NSWindow
    private let content = NSView()
    private var rows: [Row] = []
    private var config: Config
    private let onChange: (Config) -> Void

    // 刷新频率
    private let systemSlider = NSSlider(value: 5, minValue: Config.systemIntervalRange.lowerBound,
                                        maxValue: Config.systemIntervalRange.upperBound,
                                        target: nil, action: nil)
    private let systemLabel = NSTextField(labelWithString: "")
    private let quotaSlider = NSSlider(value: 120, minValue: Config.quotaIntervalRange.lowerBound,
                                       maxValue: Config.quotaIntervalRange.upperBound,
                                       target: nil, action: nil)
    private let quotaLabel = NSTextField(labelWithString: "")
    // 显示
    private let cpuCheckbox = NSButton(checkboxWithTitle: "在图标与详情中显示 CPU",
                                        target: nil, action: nil)
    private let memoryCheckbox = NSButton(checkboxWithTitle: "在图标与详情中显示内存",
                                          target: nil, action: nil)
    // 预警
    private let alertsCheckbox = NSButton(checkboxWithTitle: "启用额度预警（Dock 图标跳动）",
                                          target: nil, action: nil)
    private let thresholdSlider = NSSlider(value: 20, minValue: Config.alertThresholdRange.lowerBound,
                                          maxValue: Config.alertThresholdRange.upperBound,
                                          target: nil, action: nil)
    private let thresholdLabel = NSTextField(labelWithString: "")
    private let leadSlider = NSSlider(value: 30, minValue: Config.alertLeadRange.lowerBound,
                                      maxValue: Config.alertLeadRange.upperBound,
                                      target: nil, action: nil)
    private let leadLabel = NSTextField(labelWithString: "")
    private let streakSlider = NSSlider(value: 3, minValue: Config.alertStreakRange.lowerBound,
                                        maxValue: Config.alertStreakRange.upperBound,
                                        target: nil, action: nil)
    private let streakLabel = NSTextField(labelWithString: "")
    private let diskSlider = NSSlider(value: 200, minValue: Config.diskAlertRange.lowerBound,
                                      maxValue: Config.diskAlertRange.upperBound,
                                      target: nil, action: nil)
    private let diskLabel = NSTextField(labelWithString: "")
    // 代理
    private let proxyTitle = NSTextField(labelWithString: "Codex 代理")
    private let proxyField = NSTextField(string: "")
    /// 用可换行标签：labelWithString 不换行，长提示会被截断（实测过）。
    private let proxyHint = NSTextField(wrappingLabelWithString: "")

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Monster Pulse 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildRows()
    }

    // MARK: 行构建

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func append(_ view: NSView, height: CGFloat, gapBefore: CGFloat) {
        content.addSubview(view)
        rows.append(Row(view: view, height: height, gapBefore: gapBefore))
    }

    private func buildRows() {
        content.wantsLayer = true
        append(heading("刷新频率"), height: 15, gapBefore: 0)
        appendSlider(systemLabel, systemSlider, height: 17, gapBefore: 10)
        appendSlider(quotaLabel, quotaSlider, height: 17, gapBefore: 8)

        append(heading("显示"), height: 15, gapBefore: 20)
        for box in [cpuCheckbox, memoryCheckbox] {
            box.target = self
            box.action = #selector(checkboxChanged(_:))
            append(box, height: 20, gapBefore: box === cpuCheckbox ? 10 : 4)
        }

        append(heading("预警"), height: 15, gapBefore: 20)
        alertsCheckbox.target = self
        alertsCheckbox.action = #selector(checkboxChanged(_:))
        append(alertsCheckbox, height: 20, gapBefore: 10)
        appendSlider(thresholdLabel, thresholdSlider, height: 17, gapBefore: 8)
        appendSlider(leadLabel, leadSlider, height: 17, gapBefore: 6)
        appendSlider(streakLabel, streakSlider, height: 17, gapBefore: 6)
        appendSlider(diskLabel, diskSlider, height: 17, gapBefore: 6)

        append(heading("代理"), height: 15, gapBefore: 20)
        proxyTitle.font = .systemFont(ofSize: 12)
        proxyField.isEditable = true
        proxyField.isBezeled = true
        proxyField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        proxyField.placeholderString = "如 http://127.0.0.1:12334"
        proxyField.target = self
        proxyField.action = #selector(proxyFieldChanged)
        content.addSubview(proxyTitle)
        content.addSubview(proxyField)
        rows.append(Row(view: proxyTitle, height: 17, gapBefore: 10))
        rows.append(Row(view: proxyField, height: 20, gapBefore: -17))
        proxyHint.font = .systemFont(ofSize: 10)
        proxyHint.textColor = .secondaryLabelColor
        proxyHint.stringValue = "留空则不设代理。本应用从 Dock 启动、不经过 shell，因此读不到 .zshrc 里的代理。"
        content.addSubview(proxyHint)
        // 两行高度：提示文案较长，单行会被截断
        rows.append(Row(view: proxyHint, height: 30, gapBefore: 5))

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetToDefaults))
        content.addSubview(reset)
        resetButton = reset

        content.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: 1)
        window.contentView = content
        layoutRows()
        refreshControls()
    }

    private var resetButton: NSButton!

    /// 一个「标签 + 滑杆」行。两视图共用同一行的纵向位置与高度，
    /// 所以只由标签行计入高度，滑杆行 height=0、gapBefore=0，只负责定位。
    private func appendSlider(_ label: NSTextField, _ slider: NSSlider,
                              height: CGFloat, gapBefore: CGFloat) {
        label.font = .systemFont(ofSize: 12)
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        content.addSubview(label)
        content.addSubview(slider)
        rows.append(Row(view: label, height: height, gapBefore: gapBefore))
        rows.append(Row(view: slider, height: 0, gapBefore: 0))
    }

    /// 从上往下排版，再按内容高度调整窗口。
    ///
    /// 「标签 + 滑杆」是同一行的两个视图：滑杆行的 `gapBefore` 为负值表示
    /// 「不额外下移，与前一个标签共用 y」。此前用 `pendingGap` 延迟应用间距，
    /// 结果间距被重复应用、行序错乱，且 `contentHeight` 对负 gap 取
    /// `max(0, …)` 使每个滑杆行多算一倍高度，窗口底部因此留出大片空白。
    /// 这里改成单趟遍历：只按当前行的 gapBefore 下移，遇到滑杆则复用上一标签的 y。
    private func layoutRows() {
        var cursor = content.bounds.height
        var pairedLabelY: CGFloat?
        for row in rows {
            if row.gapBefore > 0 { cursor -= row.gapBefore }
            cursor -= row.height
            if row.view is NSSlider, let labelY = pairedLabelY {
                row.view.frame = NSRect(x: Self.inset + Self.labelWidth + 8, y: labelY,
                                        width: Self.sliderWidth, height: row.height)
                pairedLabelY = nil    // 只配对紧邻的那一个，标题不会被误配
                continue
            }
            row.view.frame = NSRect(x: Self.inset, y: cursor,
                                    width: Self.windowWidth - Self.inset * 2, height: row.height)
            pairedLabelY = (row.view is NSTextField && !(row.view is NSSlider)) ? cursor : nil
        }
    }

    /// 窗口高度 = 内容高 + 上下留白 + 底部按钮条。
    /// 滑杆行不额外计高也不额外计 gap（它的 height 已含在标签行里）。
    private var contentHeight: CGFloat {
        rows.reduce(0) { total, row in
            let gap = row.gapBefore > 0 ? row.gapBefore : 0
            return total + row.height + gap
        }
    }

    private func resizeWindow() {
        let height = contentHeight + Self.inset * 2 + Self.bottomBar
        content.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: height)
        layoutRows()
        resetButton.frame = NSRect(x: Self.inset, y: 14, width: 100, height: 28)
    }

    // MARK: 交互

    @objc private func proxyFieldChanged() {
        let raw = proxyField.stringValue
        // 输入过程中不强制改写用户的输入（例如正在输入的 "127.0" 不该被
        // 立刻变成 "http://127.0." 打断）；只在确定非法时才标红提示。
        if let normalized = ProxySetting.normalize(raw) {
            proxyHint.stringValue = "将使用：\(normalized)"
            proxyHint.textColor = .secondaryLabelColor
        } else if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            proxyHint.stringValue = "留空则不设代理。本应用从 Dock 启动、不经过 shell，因此读不到 .zshrc 里的代理。"
            proxyHint.textColor = .secondaryLabelColor
        } else {
            proxyHint.stringValue = "无法识别为代理地址，将按不设代理处理"
            proxyHint.textColor = .systemOrange
        }
        config.setProxyURL(raw)
        onChange(config)
    }

    private func refreshControls() {
        systemSlider.doubleValue = config.systemInterval
        quotaSlider.doubleValue = config.quotaInterval
        cpuCheckbox.state = config.showCPU ? .on : .off
        memoryCheckbox.state = config.showMemory ? .on : .off
        alertsCheckbox.state = config.alertsEnabled ? .on : .off
        thresholdSlider.doubleValue = config.alertQuotaThreshold
        leadSlider.doubleValue = config.alertResetLeadMinutes
        streakSlider.doubleValue = config.alertFailureStreak
        diskSlider.doubleValue = config.diskAlertMBs
        proxyField.stringValue = config.proxyURL
        updateLabels()
    }

    private func updateLabels() {
        systemLabel.stringValue = "系统指标 \(Int(systemSlider.doubleValue.rounded())) 秒"
        quotaLabel.stringValue = "额度刷新 " + Self.humanInterval(Int(quotaSlider.doubleValue.rounded()))
        thresholdLabel.stringValue = "额度剩余低于 \(Int(thresholdSlider.doubleValue.rounded()))%"
        leadLabel.stringValue = "重置前 \(Int(leadSlider.doubleValue.rounded())) 分钟内"
        streakLabel.stringValue = "连续失败 \(Int(streakSlider.doubleValue.rounded())) 次"
        diskLabel.stringValue = "磁盘超过 \(Int(diskSlider.doubleValue.rounded())) MB/s"
        // 预警关掉时三个阈值滑杆没有意义，置灰而不是隐藏——
        // 隐藏会让用户以为这个功能不存在
        let on = config.alertsEnabled
        for slider in [thresholdSlider, leadSlider, streakSlider, diskSlider] { slider.isEnabled = on }
        for label in [thresholdLabel, leadLabel, streakLabel, diskLabel] {
            label.textColor = on ? .labelColor : .disabledControlTextColor
        }
    }

    private static func humanInterval(_ seconds: Int) -> String {
        if seconds % 60 == 0 { return "\(seconds / 60) 分钟" }
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        updateLabels()
        if sender === systemSlider {
            config.setSystemInterval(sender.doubleValue.rounded())
        } else if sender === quotaSlider {
            config.setQuotaInterval(sender.doubleValue.rounded())
        } else if sender === thresholdSlider {
            config.setAlertThreshold(sender.doubleValue.rounded())
        } else if sender === leadSlider {
            config.setAlertLead(sender.doubleValue.rounded())
        } else if sender === diskSlider {
            config.setDiskAlertMBs(sender.doubleValue.rounded())
        } else {
            config.setAlertStreak(sender.doubleValue.rounded())
        }
        onChange(config)
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        if sender === cpuCheckbox {
            config.setShowCPU(sender.state == .on)
        } else if sender === memoryCheckbox {
            config.setShowMemory(sender.state == .on)
        } else {
            config.setAlertsEnabled(sender.state == .on)
        }
        updateLabels()
        onChange(config)
    }

    @objc private func resetToDefaults() {
        config.resetToDefaults()
        refreshControls()
        onChange(config)
    }

    /// 离屏渲染整个窗口内容为 PNG，用于视觉检查面板布局。
    /// 设置窗口以前没有渲染入口，新增控件是否被挤出可视区只能靠肉眼，
    /// 容易漏——详情窗口当初就是靠这个手段发现了「参考线画在 CPU 条上」的错误。
    func renderToPNG(_ path: String) {
        resizeWindow()
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    func show() {
        refreshControls()   // 每次打开都用当前生效值刷新，避免显示陈旧状态
        resizeWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window.orderOut(nil)
    }
}
