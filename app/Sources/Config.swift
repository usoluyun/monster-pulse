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

    private enum Key {
        static let systemInterval = "systemSampleInterval"
        static let quotaInterval = "quotaRefreshInterval"
        static let showCPU = "showCPU"
        static let showMemory = "showMemory"
    }

    var systemInterval: Double
    var quotaInterval: Double
    var showCPU: Bool
    var showMemory: Bool

    static let `default` = Config(systemInterval: defaultSystemInterval,
                                  quotaInterval: defaultQuotaInterval,
                                  showCPU: true, showMemory: true)

    /// 每次启动都要调用，把默认值注册进易失域。
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.systemInterval: defaultSystemInterval,
            Key.quotaInterval: defaultQuotaInterval,
            Key.showCPU: true,
            Key.showMemory: true,
        ])
    }

    static func load() -> Config {
        let d = UserDefaults.standard
        // 越界值要夹回区间：配置文件可能被手改或来自旧版本，
        // 直接拿去做 Timer 间隔会让定时器行为不可预期
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
            showMemory: d.bool(forKey: Key.showMemory))
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

    mutating func resetToDefaults() {
        self = .default
        for key in [Key.systemInterval, Key.quotaInterval, Key.showCPU, Key.showMemory] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// 采样间隔对应的定时器容差。沿用 PoC 的经验值（间隔的 20%），
    /// 让系统能合并唤醒，省电；下限 1 秒避免过度合并。
    var systemTolerance: TimeInterval { max(1, systemInterval * 0.2) }
    var quotaTolerance: TimeInterval { max(1, quotaInterval * 0.125) }
}

// MARK: - 设置面板

/// 设置窗口。改动即时生效（写 UserDefaults 并回调 AppDelegate 重启定时器），
/// 不设「确定/取消」——取消语义在这里没有意义，用户拖完滑杆就期待看到效果。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var config: Config
    private let onChange: (Config) -> Void

    private let systemSlider = NSSlider(value: 5, minValue: Config.systemIntervalRange.lowerBound,
                                        maxValue: Config.systemIntervalRange.upperBound,
                                        target: nil, action: nil)
    private let systemLabel = NSTextField(labelWithString: "")
    private let quotaSlider = NSSlider(value: 120, minValue: Config.quotaIntervalRange.lowerBound,
                                       maxValue: Config.quotaIntervalRange.upperBound,
                                       target: nil, action: nil)
    private let quotaLabel = NSTextField(labelWithString: "")
    private let cpuCheckbox = NSButton(checkboxWithTitle: "在图标与详情中显示 CPU", target: nil, action: nil)
    private let memoryCheckbox = NSButton(checkboxWithTitle: "在图标与详情中显示内存", target: nil, action: nil)

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Monster Pulse 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent()
        refreshControls()
    }

    private func buildContent() {
        let inset: CGFloat = 24
        let labelWidth: CGFloat = 108
        let sliderWidth: CGFloat = 150
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
        content.wantsLayer = true

        let heading = NSTextField(labelWithString: "刷新频率")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        content.addSubview(heading)

        for item in [(systemLabel, systemSlider), (quotaLabel, quotaSlider)] {
            let (label, slider) = item
            label.font = .systemFont(ofSize: 12)
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.isContinuous = true
            slider.numberOfTickMarks = 0
            content.addSubview(label)
            content.addSubview(slider)
        }

        for box in [cpuCheckbox, memoryCheckbox] {
            box.target = self
            box.action = #selector(checkboxChanged(_:))
            content.addSubview(box)
        }

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetToDefaults))
        reset.tag = 300
        content.addSubview(reset)

        content.frame = NSRect(x: 0, y: 0, width: 400, height: 260)
        // 手动排版，与项目既有风格一致（不引 Auto Layout）
        heading.frame = NSRect(x: inset, y: 260 - 36, width: 352, height: 15)
        for (index, item) in [(systemLabel, systemSlider), (quotaLabel, quotaSlider)].enumerated() {
            let y = CGFloat(260 - 68 - index * 34)
            item.0.frame = NSRect(x: inset, y: y, width: labelWidth, height: 17)
            item.1.frame = NSRect(x: inset + labelWidth + 8, y: y, width: sliderWidth, height: 17)
        }
        for (index, box) in [cpuCheckbox, memoryCheckbox].enumerated() {
            box.frame = NSRect(x: inset, y: CGFloat(260 - 152 - index * 26), width: 352, height: 20)
        }
        reset.frame = NSRect(x: inset, y: 20, width: 100, height: 28)
        window.contentView = content
    }

    private func refreshControls() {
        systemSlider.doubleValue = config.systemInterval
        quotaSlider.doubleValue = config.quotaInterval
        cpuCheckbox.state = config.showCPU ? .on : .off
        memoryCheckbox.state = config.showMemory ? .on : .off
        updateLabels()
    }

    private func updateLabels() {
        let seconds = Int(systemSlider.doubleValue.rounded())
        systemLabel.stringValue = "系统指标 \(seconds) 秒"
        let quotaSeconds = Int(quotaSlider.doubleValue.rounded())
        // 额度间隔跨度大，用人话读出来比秒数好懂
        quotaLabel.stringValue = "额度刷新 " + Self.humanInterval(quotaSeconds)
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
        } else {
            config.setQuotaInterval(sender.doubleValue.rounded())
        }
        onChange(config)
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        if sender === cpuCheckbox {
            config.setShowCPU(sender.state == .on)
        } else {
            config.setShowMemory(sender.state == .on)
        }
        onChange(config)
    }

    @objc private func resetToDefaults() {
        config.resetToDefaults()
        refreshControls()
        onChange(config)
    }

    func show() {
        refreshControls()   // 每次打开都用当前生效值刷新，避免显示陈旧状态
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window.orderOut(nil)
    }
}
