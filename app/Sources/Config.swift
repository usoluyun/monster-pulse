import AppKit
import ServiceManagement

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
    /// 额度轮询默认 5 分钟（原先 2 分钟）。
    ///
    /// 下调轮询频率是为了配合开机自启：自启后应用整天常驻，额度查询每次都要
    /// spawn 一个 codex app-server 子进程。120 秒意味着一天 720 次，300 秒是 288 次。
    /// 额度本身变化很慢——5 小时窗口里用掉 20% 通常要一小时以上，2 分钟与 5 分钟
    /// 的显示差异远小于用户看 Dock 的间隔。
    ///
    /// 只改默认值不改区间：已显式设过值的用户配置会被保留，不被默认值覆盖。
    static let defaultQuotaInterval = 300.0

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
        static let showGPU = "showGPU"
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
    /// GPU 占用是否显示。跑本地大模型时这是唯一有区分度的指标。
    var showGPU: Bool
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
                                  showCPU: true, showMemory: true, showGPU: true,
                                  alertsEnabled: true,
                                  alertQuotaThreshold: defaultAlertThreshold,
                                  alertResetLeadMinutes: defaultAlertLead,
                                  alertFailureStreak: defaultAlertStreak,
                                  diskAlertMBs: defaultDiskAlert,
                                  proxyURL: "")

    /// 每次启动都要调用，把默认值注册进易失域。
    static func registerDefaults(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.systemInterval: defaultSystemInterval,
            Key.quotaInterval: defaultQuotaInterval,
            Key.showCPU: true,
            Key.showMemory: true,
            Key.showGPU: true,
            Key.alertsEnabled: true,
            Key.alertThreshold: defaultAlertThreshold,
            Key.alertLead: defaultAlertLead,
            Key.alertStreak: defaultAlertStreak,
            Key.diskAlertThreshold: defaultDiskAlert,
            Key.proxyURL: "",
        ])
    }

    static func load(defaults d: UserDefaults = .standard) -> Config {
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
            showMemory: true,
            showGPU: d.bool(forKey: Key.showGPU),
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
    mutating func setShowGPU(_ value: Bool) {
        showGPU = value
        UserDefaults.standard.set(value, forKey: Key.showGPU)
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
                    Key.showGPU, Key.alertsEnabled, Key.alertThreshold, Key.alertLead, Key.alertStreak,
                    Key.diskAlertThreshold, Key.proxyURL] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// 采样间隔对应的定时器容差。沿用 PoC 的经验值（间隔的 20%），
    /// 让系统能合并唤醒，省电；下限 1 秒避免过度合并。
    var systemTolerance: TimeInterval { max(1, systemInterval * 0.2) }
    var quotaTolerance: TimeInterval { max(1, quotaInterval * 0.125) }
}


// MARK: - 开机自启

/// 「登录时启动」的封装。
///
/// **事实源是系统的 `SMAppService` 状态，不是本地配置。** 用户也可以在
/// 「系统设置 → 通用 → 登录项」里改开关，所以面板里的勾选只是系统状态的显示，
/// 不维护第二份真相。每次打开面板都重新读 `status`，别信上次写进去的值——
/// 这正是 AGENTS.md 验证纪律第 3 条那个坑的翻版。
enum LaunchAtLogin {
    /// 没有 bundle id 就无法注册登录项。
    ///
    /// 实测（2026-10-07）：`--standalone` 产物无 Info.plist，查 `status` 不崩，
    /// 返回 `.notFound`。所以这里不抛异常，只是功能不可用。
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    /// 登录时是否会启动。`.requiresApproval` 也算「已开启」——注册请求已提交，
    /// 只是还等用户在系统设置里放行。
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// 系统实际状态的中文说明。措辞区分「待批准」，因为那一步必须用户自己做。
    static var statusText: String {
        guard isSupported else {
            return "当前产物没有 bundle id，无法注册登录项（--standalone 形态不支持开机自启）"
        }
        switch SMAppService.mainApp.status {
        case .enabled:      return "已启用：下次登录时由系统自动启动"
        case .requiresApproval:
            return "已注册，等待批准：需在「系统设置 → 通用 → 登录项」中打开本应用的开关"
        case .notRegistered: return "未启用"
        case .notFound:      return "系统未找到本应用的可登录项，请先从 .app 形态启动一次"
        @unknown default:    return "系统返回了未知状态（rawValue \(SMAppService.mainApp.status.rawValue)）"
        }
    }

    /// 打开登录项设置面板。失败时返回 false，由调用方决定是否提示。
    @discardableResult
    static func openSystemSettings() -> Bool {
        // 面板扩展实测存在于 /System/Library/ExtensionKit/Extensions/LoginItems.appex。
        // URL scheme 的实际跳转效果无法在终端验证，需用户点一次确认。
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
              NSWorkspace.shared.open(url) else { return false }
        return true
    }
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
        /// nil 表示占满内容宽度；给具体值则按内容宽排（左对齐），用于次要按钮。
        var width: CGFloat?
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
    private let gpuCheckbox = NSButton(checkboxWithTitle: "在图标与详情中显示 GPU 占用",
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
    private let proxyTitle = NSTextField(labelWithString: "应用代理")
    private let proxyField = NSTextField(string: "")
    /// 用可换行标签：labelWithString 不换行，长提示会被截断（实测过）。
    private let proxyHint = NSTextField(wrappingLabelWithString: "")
    // 开机自启
    private let launchCheckbox = NSButton(checkboxWithTitle: "登录时自动启动",
                                          target: nil, action: nil)
    private let launchHint = NSTextField(wrappingLabelWithString: "")
    private let launchSettingsButton = NSButton(title: "打开「登录项」设置…",
                                                target: nil, action: nil)

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

    private func append(_ view: NSView, height: CGFloat, gapBefore: CGFloat, width: CGFloat? = nil) {
        content.addSubview(view)
        rows.append(Row(view: view, height: height, gapBefore: gapBefore, width: width))
    }

    private func buildRows() {
        content.wantsLayer = true
        append(heading("刷新频率"), height: 15, gapBefore: 0)
        appendSlider(systemLabel, systemSlider, height: 17, gapBefore: 10)
        appendSlider(quotaLabel, quotaSlider, height: 17, gapBefore: 8)

        append(heading("显示"), height: 15, gapBefore: 20)
        for box in [cpuCheckbox, gpuCheckbox] {
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
        rows.append(Row(view: proxyTitle, height: 17, gapBefore: 10, width: nil))
        rows.append(Row(view: proxyField, height: 20, gapBefore: -17, width: nil))
        proxyHint.font = .systemFont(ofSize: 10)
        proxyHint.textColor = .secondaryLabelColor
        proxyHint.stringValue = "用于 Codex 查询和出口 IP 探测。留空时出口探测使用系统代理；不读取 shell 代理。"
        content.addSubview(proxyHint)
        // 两行高度：提示文案较长，单行会被截断
        rows.append(Row(view: proxyHint, height: 30, gapBefore: 5, width: nil))

        buildLaunchRows()

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetToDefaults))
        content.addSubview(reset)
        resetButton = reset

        content.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: 1)
        window.contentView = content
        layoutRows()
        refreshControls()
    }

    /// 「启动」分组。自启状态由 `LaunchAtLogin` 从系统读，本地不留副本。
    private func buildLaunchRows() {
        append(heading("启动"), height: 15, gapBefore: 20)
        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchCheckboxChanged)
        append(launchCheckbox, height: 20, gapBefore: 10)
        launchHint.font = .systemFont(ofSize: 10)
        launchHint.textColor = .secondaryLabelColor
        append(launchHint, height: 30, gapBefore: 5)
        launchSettingsButton.target = self
        launchSettingsButton.action = #selector(openLoginItems)
        append(launchSettingsButton, height: 24, gapBefore: 6, width: 220)
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
        rows.append(Row(view: label, height: height, gapBefore: gapBefore, width: nil))
        rows.append(Row(view: slider, height: 0, gapBefore: 0, width: nil))
    }

    /// 从上往下排版，再按内容高度调整窗口。
    ///
    /// 「标签 + 滑杆」是同一行的两个视图：滑杆行的 `gapBefore` 为负值表示
    /// 「不额外下移，与前一个标签共用 y」。此前用 `pendingGap` 延迟应用间距，
    /// 结果间距被重复应用、行序错乱，且 `contentHeight` 对负 gap 取
    /// `max(0, …)` 使每个滑杆行多算一倍高度，窗口底部因此留出大片空白。
    /// 这里改成单趟遍历：只按当前行的 gapBefore 下移，遇到滑杆则复用上一标签的 y。
    private func layoutRows() {
        // 从 content.bounds.height - inset 起排，留出顶部内边距。
        //
        // 此前从 bounds.height 起排，等于把首行顶到内容视图的最上沿：顶部 24pt
        // 内边距整个没落到内容上，改为在底部多留 24pt 死白。窗口高度是按
        // contentHeight + 2*inset + bottomBar 算的，所以底部那段空白看起来「正常」，
        // 布局诊断也判「足够」——它只查够不够高，查不出留白摆错了位置。
        var cursor = content.bounds.height - Self.inset
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
                                    width: row.width ?? (Self.windowWidth - Self.inset * 2),
                                    height: row.height)
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

    /// 按内容高度调整窗口。
    ///
    /// 必须走 `window.setContentSize(_:)`，不能直接改 `content.frame`：
    /// NSWindow 会用窗口尺寸强制覆盖 contentView 的 frame，直接赋值会被丢掉。
    /// 那样真窗口里内容区仍是创建时的 480pt，而布局是从 `content.bounds.height`
    /// 往下排的，行数不够时就排到了窗口上边界之外——顶部几项被裁掉看不见。
    /// 离屏渲染发现不了这个问题，因为它按 content 的 frame 渲染，
    /// 恰好是「算对了」的那个高度。
    private func resizeWindow() {
        let height = contentHeight + Self.inset * 2 + Self.bottomBar
        window.setContentSize(NSSize(width: Self.windowWidth, height: height))
        layoutRows()
        resetButton.frame = NSRect(x: Self.inset, y: 14, width: 100, height: 28)
    }

    /// 诊断用：内容实际需要多高、窗口**实际提供**多高的内容区、有没有把顶部裁掉。
    ///
    /// 判据必须用 `window.contentLayoutRect.height` 而不是 `content.bounds.height`：
    /// 后者读的是我们自己刚赋值的 frame，只改 content.frame 而没调
    /// setContentSize 时它照样是「够高」的值（窗口要到真正显示时才把 frame 压回去），
    /// 因此完全测不出这个 bug。contentLayoutRect 才是窗口实际给出的可用高度。
    func layoutDiagnostics() -> String {
        let needed = contentHeight + Self.inset * 2 + Self.bottomBar
        let capacity = window.contentLayoutRect.height
        let topMost = rows.map { $0.view.frame.maxY }.max() ?? 0
        // 顶部留白必须接近 inset。少了说明首行顶到了上沿；多了说明内边距
        // 被挪到了底部。这条判据是靠肉眼看出来的 bug，只查「够不够高」查不出。
        let topGap = capacity - topMost
        let gapOK = abs(topGap - Self.inset) <= 1.5
        return String(format: "需要 %.0fpt，窗口提供 %.0fpt，%@；最上元素顶端 %.0fpt %@；顶部留白 %.0fpt %@",
                      needed, capacity,
                      capacity + 0.5 >= needed ? "足够" : "不足(顶部被裁)",
                      topMost, capacity + 0.5 >= topMost ? "在可视区内" : "超出可视区",
                      topGap, gapOK ? "正常" : "异常(应为 \(Int(Self.inset))pt)")
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
            proxyHint.stringValue = "用于 Codex 查询和出口 IP 探测。留空时出口探测使用系统代理；不读取 shell 代理。"
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
        gpuCheckbox.state = config.showGPU ? .on : .off
        alertsCheckbox.state = config.alertsEnabled ? .on : .off
        thresholdSlider.doubleValue = config.alertQuotaThreshold
        leadSlider.doubleValue = config.alertResetLeadMinutes
        streakSlider.doubleValue = config.alertFailureStreak
        diskSlider.doubleValue = config.diskAlertMBs
        proxyField.stringValue = config.proxyURL
        refreshLaunchControls()
        updateLabels()
    }

    /// 开机自启控件。勾选状态与提示文案**一律从系统读**，不读本地配置。
    ///
    /// 视觉回归要可重复，而自启状态是机器上的真实状态（用户可能已在系统设置里
    /// 改过），所以离屏渲染时由夹具注入固定值，避免基线图随机器状态漂移。
    /// 这不是造自己的环境——渲染只画外观，不验证注册行为，注册行为另有实测。
    var renderLaunchAtLoginOverride: Bool?

    private func refreshLaunchControls() {
        let supported = LaunchAtLogin.isSupported
        if let override = renderLaunchAtLoginOverride {
            launchCheckbox.state = override ? .on : .off
            launchHint.stringValue = override
                ? "渲染夹具：模拟已启用状态（真实状态从系统登录项读取）"
                : "渲染夹具：模拟未启用状态"
        } else {
            launchCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
            launchHint.stringValue = LaunchAtLogin.statusText
        }
        launchCheckbox.isEnabled = supported
        launchSettingsButton.isEnabled = supported
    }

    @objc private func launchCheckboxChanged() {
        guard LaunchAtLogin.isSupported else { refreshLaunchControls(); return }
        let want = launchCheckbox.state == .on
        do {
            if want {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let ns = error as NSError
            NSLog("SMAppService %@ 失败: %@ %ld %@",
                  want ? "register" : "unregister", ns.domain, ns.code, ns.localizedDescription)
        }
        // 无论成败都重读系统状态：失败时勾选会被纠正回真实值，
        // 而不是留下「面板说开了、系统其实没开」的错觉。
        refreshLaunchControls()
    }

    @objc private func openLoginItems() {
        if LaunchAtLogin.openSystemSettings() { return }
        let alert = NSAlert()
        alert.messageText = "无法打开登录项设置"
        alert.informativeText = "请手动前往「系统设置 → 通用 → 登录项」查看本应用。"
        alert.runModal()
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
        } else if sender === gpuCheckbox {
            config.setShowGPU(sender.state == .on)
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
    /// 渲染时使用的外观。由 --settings-render-test 注入，见 main.swift 里的说明。
    var renderAppearance: NSAppearance?

    func renderToPNG(_ path: String) {
        if let appearance = renderAppearance {
            content.appearance = appearance
            window.appearance = appearance
        }
        // 必须自己垫一层窗口背景色。
        //
        // contentView 是 wantsLayer 且没有自己的底色，直接 cacheDisplay 得到的
        // 位图背景是**透明**的。真实窗口里看不出来——窗口自己垫了
        // windowBackgroundColor；离屏渲染没有窗口，就成了「白字 + 透明底」，
        // 文字整个消失（DetailsView 在 draw() 里自己填了底色，所以它没事）。
        //
        // 这个坑被另一个 bug 掩盖了很久：renderAppearance 原先声明在使用之后，
        // 设置面板那次读到的是 nil，appearance 没生效、文字按系统外观成了深色，
        // 深字配透明底反而「能看见」。修掉前向引用后深色没了，它才暴露出来。
        //
        // 必须在设完 appearance 之后再取 cgColor，否则动态色会按当时的当前外观
        // 解析，而不是 darkAqua——那就等于白垫。
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        // 夹具是在 init 之后才注入的（renderLaunchAtLoginOverride / renderAppearance），
        // 而 refreshControls() 在 buildRows() 里已经跑过一次。不重刷就等于用注入前
        // 的状态出图——login-on 夹具会画出「未启用」，看起来像功能没实现。
        refreshControls()
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
