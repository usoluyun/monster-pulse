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
        static let showDisk = "showDisk"
        static let alertsEnabled = "alertsEnabled"
        static let alertThreshold = "alertQuotaThreshold"
        static let alertLead = "alertResetLeadMinutes"
        static let alertStreak = "alertFailureStreak"
        static let diskAlertThreshold = "diskReadAlertMBs"
        static let proxyURL = "codexProxyURL"
        static let quotaSource = "quotaSource"
        static let newAPIBaseURL = "newAPIBaseURL"
        static let newAPIFollowAppProxy = "newAPIFollowAppProxy"
    }

    var systemInterval: Double
    var quotaInterval: Double
    var showCPU: Bool
    var showMemory: Bool
    /// GPU 占用是否显示。跑本地大模型时这是唯一有区分度的指标。
    var showGPU: Bool
    var showDisk: Bool = true
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

    /// 额度来源。M3 引入，默认 Codex 以保持既有行为不变。
    var quotaSource: QuotaSource = .codex

    /// New API 服务地址。
    ///
    /// 这里**不含访问令牌**。令牌存 Keychain（见 KeychainStore），
    /// 不走 UserDefaults——`proxyURL` 那条注释的前提「只代理 localhost，
    /// 一般不含凭据」在这里不成立。
    var newAPIBaseURL: String = ""

    /// New API 访问令牌是否已保存。只记布尔值，不记内容。
    var hasNewAPIToken: Bool { KeychainStore.read(service: KeychainStore.Slot.service,
                                                    account: KeychainStore.Slot.accountToken) != nil }

    /// New API 是否跟随「应用代理」。默认直连——内网域名进代理常会连不通。
    var newAPIFollowAppProxy: Bool = false

    var monster = MonsterAppearance()

    /// 当前来源的四表面 Profile。
    var profile: ProviderProfile { ProviderProfile.of(quotaSource) }

    static let `default` = Config(systemInterval: defaultSystemInterval,
                                  quotaInterval: defaultQuotaInterval,
                                  showCPU: true, showMemory: true, showGPU: true,
                                  alertsEnabled: true,
                                  alertQuotaThreshold: defaultAlertThreshold,
                                  alertResetLeadMinutes: defaultAlertLead,
                                  alertFailureStreak: defaultAlertStreak,
                                  diskAlertMBs: defaultDiskAlert,
                                  proxyURL: "", quotaSource: .codex, newAPIBaseURL: "",
                                  newAPIFollowAppProxy: false)

    /// 每次启动都要调用，把默认值注册进易失域。
    static func registerDefaults(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.systemInterval: defaultSystemInterval,
            Key.quotaInterval: defaultQuotaInterval,
            Key.showCPU: true,
            Key.showMemory: true,
            Key.showGPU: true,
            Key.showDisk: true,
            Key.alertsEnabled: true,
            Key.alertThreshold: defaultAlertThreshold,
            Key.alertLead: defaultAlertLead,
            Key.alertStreak: defaultAlertStreak,
            Key.diskAlertThreshold: defaultDiskAlert,
            Key.proxyURL: "",
            Key.quotaSource: QuotaSource.codex.rawValue,
            Key.newAPIBaseURL: "",
            Key.newAPIFollowAppProxy: false,
        ])
    }

    static func load(defaults d: UserDefaults = .standard) -> Config {
        // 越界值要夹回区间：配置文件可能被手改或来自旧版本，
        // 直接拿去做 Timer 间隔或阈值会让行为不可预期
        let clamp = { (value: Double, range: ClosedRange<Double>, fallback: Double) in
            guard value.isFinite, range.contains(value) else { return fallback }
            return value
        }
        var config = Config(
            systemInterval: clamp(d.double(forKey: Key.systemInterval),
                                   systemIntervalRange, defaultSystemInterval),
            quotaInterval: clamp(d.double(forKey: Key.quotaInterval),
                                 quotaIntervalRange, defaultQuotaInterval),
            showCPU: d.bool(forKey: Key.showCPU),
            showMemory: d.bool(forKey: Key.showMemory),
            showGPU: d.bool(forKey: Key.showGPU),
            showDisk: d.bool(forKey: Key.showDisk),
            alertsEnabled: d.bool(forKey: Key.alertsEnabled),
            alertQuotaThreshold: clamp(d.double(forKey: Key.alertThreshold),
                                       alertThresholdRange, defaultAlertThreshold),
            alertResetLeadMinutes: clamp(d.double(forKey: Key.alertLead),
                                         alertLeadRange, defaultAlertLead),
            alertFailureStreak: clamp(d.double(forKey: Key.alertStreak),
                                      alertStreakRange, defaultAlertStreak),
            diskAlertMBs: clamp(d.double(forKey: Key.diskAlertThreshold),
                                diskAlertRange, defaultDiskAlert),
            proxyURL: d.string(forKey: Key.proxyURL) ?? "",
            // 存盘值可能被手改成任意字符串，解析失败要回退默认而不是崩。
            quotaSource: d.string(forKey: Key.quotaSource)
                .flatMap(QuotaSource.init(rawValue:)) ?? .codex,
            newAPIBaseURL: d.string(forKey: Key.newAPIBaseURL) ?? "",
            newAPIFollowAppProxy: d.object(forKey: Key.newAPIFollowAppProxy) == nil
                ? false : d.bool(forKey: Key.newAPIFollowAppProxy))
        if let data = d.data(forKey: "monsterAppearance"),
           let value = try? JSONDecoder().decode(MonsterAppearance.self, from: data) {
            config.monster = value.validated()
        }
        return config
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
    mutating func setShowDisk(_ value: Bool) {
        showDisk = value
        UserDefaults.standard.set(value, forKey: Key.showDisk)
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

    mutating func setQuotaSource(_ value: QuotaSource) {
        quotaSource = value
        UserDefaults.standard.set(value.rawValue, forKey: Key.quotaSource)
    }

    /// 服务地址。存盘前规范化，补上 https:// 并去掉尾部斜杠。
    mutating func setNewAPIBaseURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        newAPIBaseURL = NewAPISettings.normalizeBaseURL(trimmed) ?? ""
        UserDefaults.standard.set(newAPIBaseURL, forKey: Key.newAPIBaseURL)
    }

    /// 规范化后的服务地址。nil 表示未配置或格式无效。
    var newAPIURL: URL? {
        guard !newAPIBaseURL.isEmpty else { return nil }
        return URL(string: newAPIBaseURL)
    }

    mutating func setNewAPIFollowAppProxy(_ value: Bool) {
        newAPIFollowAppProxy = value
        UserDefaults.standard.set(value, forKey: Key.newAPIFollowAppProxy)
    }

    /// New API 请求实际使用的代理。默认直连；仅当用户勾选「跟随应用代理」
    /// 且应用代理可解析时才返回 URL。
    ///
    /// 不默认继承：公司内网域名进代理常会连不通。
    var newAPIProxy: URL? {
        guard newAPIFollowAppProxy, let proxy = effectiveProxy else { return nil }
        return URL(string: proxy)
    }

    mutating func setMonster(_ value: MonsterAppearance) {
        monster = value.validated()
        if let data = try? JSONEncoder().encode(monster) {
            UserDefaults.standard.set(data, forKey: "monsterAppearance")
        }
    }

    /// 规范化后的代理，nil 表示不设代理。查询时注入子进程环境。
    var effectiveProxy: String? { ProxySetting.normalize(proxyURL) }

    mutating func resetToDefaults() {
        self = .default
        for key in [Key.systemInterval, Key.quotaInterval, Key.showCPU, Key.showMemory,
                    Key.showGPU, Key.showDisk, Key.alertsEnabled, Key.alertThreshold, Key.alertLead, Key.alertStreak,
                    Key.diskAlertThreshold, Key.proxyURL, Key.newAPIFollowAppProxy, "monsterAppearance"] {
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
    /// 额度来源切换回调。设置页不直接改 AppDelegate 状态，由外部接上
    /// switchQuotaSource——那里才有世代推进与在途请求丢弃的逻辑。
    private let onQuotaSourceChanged: (QuotaSource) -> Void
    /// 「检查连接」跑在后台队列，不阻塞设置窗口。
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

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
    private let memoryCheckbox = NSButton(checkboxWithTitle: "在图标与详情中显示内存", target: nil, action: nil)
    private let diskCheckbox = NSButton(checkboxWithTitle: "在图标与详情中显示磁盘读写", target: nil, action: nil)
    // 额度来源（M3）
    private let sourcePicker = NSSegmentedControl(labels: QuotaSource.allCases.map(\.label),
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let newAPIAddressTitle = NSTextField(labelWithString: "服务地址")
    private let newAPIAddressField = NSTextField(string: "")
    private let newAPITokenTitle = NSTextField(labelWithString: "访问令牌")
    private let newAPITokenField = NSSecureTextField(string: "")
    private let pasteTokenButton = NSButton(title: "从剪贴板粘贴", target: nil, action: nil)
    private let newAPIStatus = NSTextField(wrappingLabelWithString: "")
    private let checkConnectionButton = NSButton(title: "检查连接", target: nil, action: nil)
    private let clearTokenButton = NSButton(title: "清除令牌", target: nil, action: nil)
    /// 渲染夹具覆盖令牌已保存态。nil 时读真实 Keychain。
    ///
    /// 真实态取决于这台机器填过令牌没有——照着真值画，基线图就会随机器
    /// 状态漂移（这跟自启状态、.build vs /Applications 是同一类问题）。
    var renderHasNewAPITokenOverride: Bool?
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
    // 网络（应用代理 + 按来源的跟随选项）
    private let proxyTitle = NSTextField(labelWithString: "应用代理")
    private let proxyField = NSTextField(string: "")
    /// 用可换行标签：labelWithString 不换行，长提示会被截断（实测过）。
    private let proxyHint = NSTextField(wrappingLabelWithString: "")
    private let followAppProxyCheckbox = NSButton(
        checkboxWithTitle: ProviderProfile.followAppProxyTitle, target: nil, action: nil)
    private let walletAlertNote = NSTextField(wrappingLabelWithString:
        "钱包预警按富足度档位：偏紧 / 见底时 Dock 图标跳动。无百分比阈值与重置窗口。")
    // 开机自启
    private let launchCheckbox = NSButton(checkboxWithTitle: "登录时自动启动",
                                          target: nil, action: nil)
    private let launchHint = NSTextField(wrappingLabelWithString: "")
    private let launchSettingsButton = NSButton(title: "打开「登录项」设置…",
                                                target: nil, action: nil)

    init(config: Config, onChange: @escaping (Config) -> Void,
         onQuotaSourceChanged: @escaping (QuotaSource) -> Void = { _ in }) {
        self.config = config
        self.onChange = onChange
        self.onQuotaSourceChanged = onQuotaSourceChanged
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Monster Pulse 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildRows()
    }

    // MARK: 行构建

    /// 切换来源后整段重排。
    ///
    /// 旧实现会把 New API 的地址、令牌、检查连接几行留在原地并置灰，
    /// 但那样用户仍能点到输入框、也能看到占位符，很容易以为配置还在生效。
    /// 直接重建更符合「不可用的配置不该可见」。
    private func rebuildRows() {
        content.subviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        buildRows()
        resizeWindow()
    }

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
        let monsterButton = NSButton(title: "Monster 外观…", target: self, action: #selector(openMonsterAppearance))
        monsterAppearanceButton = monsterButton
        content.addSubview(monsterButton)
        append(heading("刷新频率"), height: 15, gapBefore: 0)
        appendSlider(systemLabel, systemSlider, height: 17, gapBefore: 10)
        appendSlider(quotaLabel, quotaSlider, height: 17, gapBefore: 8)

        buildSourceRows()

        append(heading("显示"), height: 15, gapBefore: 20)
        for box in [cpuCheckbox, gpuCheckbox, memoryCheckbox, diskCheckbox] {
            box.target = self
            box.action = #selector(checkboxChanged(_:))
            append(box, height: 20, gapBefore: box === cpuCheckbox ? 10 : 4)
        }

        let meterHint = NSTextField(wrappingLabelWithString: "图标上排 CPU / GPU，下排内存 / 磁盘。磁盘左橙读、右黄写，满格 800 MB/s；隐藏后其余柱状图自动填满。")
        meterHint.font = .systemFont(ofSize: 11)
        meterHint.textColor = .secondaryLabelColor
        append(meterHint, height: 32, gapBefore: 6)

        buildAlertRows()
        buildNetworkRows()
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
    /// 额度来源段。选 Codex 时把 New API 的几行折叠掉——
    /// 让不可用的配置项保持可见只会让人以为它在生效。
    private func buildSourceRows() {
        append(heading("额度来源"), height: 15, gapBefore: 20)
        sourcePicker.target = self
        sourcePicker.action = #selector(sourceChanged)
        content.addSubview(sourcePicker)
        rows.append(Row(view: sourcePicker, height: 24, gapBefore: 10, width: nil))

        sourcePicker.selectedSegment = QuotaSource.allCases.firstIndex(of: config.quotaSource) ?? 0
        guard config.quotaSource == .newAPI else { return }
        newAPIAddressField.stringValue = config.newAPIBaseURL

        newAPIAddressTitle.font = .systemFont(ofSize: 12)
        newAPIAddressField.isEditable = true
        newAPIAddressField.isBezeled = true
        newAPIAddressField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        newAPIAddressField.placeholderString = "https://codingplan.at-our.com"
        newAPIAddressField.target = self
        newAPIAddressField.action = #selector(newAPIAddressChanged)
        content.addSubview(newAPIAddressTitle)
        content.addSubview(newAPIAddressField)
        rows.append(Row(view: newAPIAddressTitle, height: 17, gapBefore: 12, width: nil))
        rows.append(Row(view: newAPIAddressField, height: 20, gapBefore: -17, width: nil))

        newAPITokenTitle.font = .systemFont(ofSize: 12)
        // 安全输入框：令牌不在屏幕上以明文出现。
        //
        // ⚠️ 但它会**拒绝粘贴**来自其他安全字段的内容——macOS 的防肩窥设计。
        // 令牌通常正是从密码管理器或安全输入框复制的，所以实测：
        // 地址框（普通 NSTextField）能粘、令牌框能打字、唯独这个框不能粘。
        // 因此额外提供「粘贴」按钮直接读剪贴板，绕过安全框的粘贴路径，
        // 而显示仍然保持遮罩——这是保留遮罩又能用上的唯一办法。
        newAPITokenField.isEditable = true
        newAPITokenField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        refreshTokenState()
        newAPITokenField.target = self
        newAPITokenField.action = #selector(newAPITokenChanged)
        // 只有按回车才保存。默认的 sendsActionOnEndEditing 会在失焦时也触发，
        // 那意味着粘贴后随手点别处就把半截内容存进去了。
        newAPITokenField.cell?.sendsActionOnEndEditing = false
        selectAllOnFocus()
        content.addSubview(newAPITokenTitle)
        content.addSubview(newAPITokenField)
        rows.append(Row(view: newAPITokenTitle, height: 17, gapBefore: 8, width: nil))
        rows.append(Row(view: newAPITokenField, height: 20, gapBefore: -17, width: nil))
        pasteTokenButton.target = self
        pasteTokenButton.action = #selector(pasteTokenFromClipboard)
        content.addSubview(pasteTokenButton)
        rows.append(Row(view: pasteTokenButton, height: 20, gapBefore: 5, width: nil))

        checkConnectionButton.target = self
        checkConnectionButton.action = #selector(checkNewAPIConnection)
        content.addSubview(checkConnectionButton)
        rows.append(Row(view: checkConnectionButton, height: 22, gapBefore: 10, width: nil))

        clearTokenButton.target = self
        clearTokenButton.action = #selector(clearNewAPIToken)
        content.addSubview(clearTokenButton)
        rows.append(Row(view: clearTokenButton, height: 22, gapBefore: 2, width: nil))

        newAPIStatus.font = .systemFont(ofSize: 10)
        newAPIStatus.textColor = .secondaryLabelColor
        newAPIStatus.stringValue = "令牌存 macOS 钥匙串，不写入偏好设置、不进日志。New API 不提供周期额度窗口，因此不显示时间进度环。"
        content.addSubview(newAPIStatus)
        // 三行：提示较长，单行会被截断
        rows.append(Row(view: newAPIStatus, height: 42, gapBefore: 6, width: nil))
    }

    @objc private func sourceChanged() {
        let next = QuotaSource.allCases[max(0, sourcePicker.selectedSegment)]
        config.setQuotaSource(next)
        rebuildRows()
        // 换来源必须走切换路径：推进世代、丢弃在途旧结果、清空旧显示。
        onQuotaSourceChanged(next)
    }

    @objc private func newAPIAddressChanged() {
        config.setNewAPIBaseURL(newAPIAddressField.stringValue)
        newAPIAddressField.stringValue = config.newAPIBaseURL
    }

    /// 令牌保存态的视觉表现。
    ///
    /// 单独抽出来，因为渲染夹具是在 init 之后才注入 `renderHasNewAPITokenOverride`
    /// 的，而 buildRows() 在 init 里就跑过一次——不重刷就会用注入前的状态出图。
    /// refreshControls() 由 renderToPNG 调用，这里也调，两处共用同一套判定。
    private func refreshTokenState() {
        let hasToken = renderHasNewAPITokenOverride ?? config.hasNewAPIToken
        newAPITokenField.placeholderString = hasToken ? "已保存在钥匙串，留空则不修改" : "账户访问令牌"
        clearTokenButton.isEnabled = hasToken
    }

    /// 从剪贴板直接取文本填入令牌框。
    ///
    /// 存在的唯一理由是绕开 `NSSecureTextField` 的粘贴限制——它会拒绝来自
    /// 其他安全字段的内容（macOS 防肩窥），而令牌基本都来自密码管理器或
    /// 安全输入框。所以「⌘V 无效、打字有效」是这个控件的固有行为，
    /// 不是配置或焦点问题（地址框能粘、令牌框能打字，都证明那两项正常）。
    ///
    /// 显示仍是遮罩：写进 `stringValue` 的内容由安全框自己遮住，不落到屏幕上。
    @objc private func pasteTokenFromClipboard() {
        let pb = NSPasteboard.general
        // 依次尝试常见文本类型：密码管理器与浏览器不一定给 .string
        var text: String?
        for type in [NSPasteboard.PasteboardType.string, .init("public.utf8-plain-text"), .init("public.text")] {
            if let value = pb.string(forType: type), !value.isEmpty { text = value; break }
        }
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            newAPIStatus.stringValue = "剪贴板里没有可用的文本。请确认复制的确实是令牌本身。"
            NSSound.beep()
            return
        }
        newAPITokenField.stringValue = value
        // 填完直接落盘，不必再按一次回车——按钮本身就是明确的保存动作。
        newAPITokenChanged()
    }

    @objc private func newAPITokenChanged() {
        let typed = newAPITokenField.stringValue
        guard !typed.isEmpty else { return }
        let ok = KeychainStore.save(typed, service: KeychainStore.Slot.service,
                                    account: KeychainStore.Slot.accountToken)
        if ok {
            // 保存后**不要清空输入框**。
            //
            // 之前保存完就把 stringValue 置空，而 NSTextField 的
            // sendsActionOnEndEditing 默认 true——粘贴后再点一下别处就会触发
            // action 并清空，用户看到空框，误以为粘贴没生效（实测反馈）。
            // 安全框本身遮罩显示，留着不泄露；留着还能让「粘进去了」可见。
            newAPITokenField.placeholderString = "已保存到钥匙串"
            clearTokenButton.isEnabled = true
            newAPIStatus.stringValue = "访问令牌已保存到钥匙串：不回显、不写偏好设置。再次粘贴会替换。"
        } else {
            newAPIStatus.stringValue = "保存失败：钥匙串写入被拒绝，可能缺少权限。"
        }
    }

    @objc private func clearNewAPIToken() {
        _ = KeychainStore.delete(service: KeychainStore.Slot.service,
                                 account: KeychainStore.Slot.accountToken)
        newAPITokenField.stringValue = ""
        newAPITokenField.placeholderString = "账户访问令牌"
        clearTokenButton.isEnabled = false
        newAPIStatus.stringValue = "已删除钥匙串中的访问令牌。"
    }

    /// 焦点进入时全选：再次粘贴是替换而不是追加。
    ///
    /// 保存后刻意保留了输入框内容（遮罩显示），所以不清空就得处理「再粘一次
    /// 会追加」的问题。NSTextField 没有 focus 回调，用 didBecomeFirstResponder
    /// 的字段编辑器通知来挂钩。
    private func selectAllOnFocus() {
        NotificationCenter.default.addObserver(
            forName: NSControl.textDidBeginEditingNotification, object: newAPITokenField,
            queue: .main) { [weak self] note in
            guard let editor = note.object as? NSTextField else { return }
            self?.newAPITokenField.currentEditor()?.selectAll(nil)
        }
    }

    /// 「检查连接」在后台跑，界面先回「检查中…」再更新结果。
    @objc private func checkNewAPIConnection() {
        guard let base = config.newAPIURL else {
            newAPIStatus.stringValue = "服务地址无效：需要形如 https://example.com 的地址"
            return
        }
        guard config.hasNewAPIToken else {
            newAPIStatus.stringValue = "尚未保存访问令牌"
            return
        }
        guard let token = KeychainStore.read(service: KeychainStore.Slot.service,
                                             account: KeychainStore.Slot.accountToken) else { return }
        newAPIStatus.stringValue = "检查中…"
        checkConnectionButton.isEnabled = false
        let client = NewAPIClient(baseURL: base, accessToken: token, proxyURL: config.newAPIProxy)
        queue.addOperation {
            let message: String
            do { message = Self.describe(try client.checkConnection()) }
            catch { message = error.localizedDescription }
            DispatchQueue.main.async {
                self.checkConnectionButton.isEnabled = true
                self.newAPIStatus.stringValue = message
            }
        }
    }

    private static func describe(_ diagnostics: NewAPIClient.Diagnostics) -> String {
        var parts = ["连接成功 \(diagnostics.version)", diagnostics.balanceNote,
                     diagnostics.unitNote, "富足度：\(diagnostics.prosperity.label)"]
        parts.append(diagnostics.hasSubscription ? "检测到套餐，按套餐额度比例显示" : "无套餐，按预计可用天数显示")
        return parts.joined(separator: " · ")
    }

    /// 预警区按当前 Profile 显隐：New API 不得出现「剩余% / 重置前」。
    private func buildAlertRows() {
        let profile = config.profile
        append(heading("预警"), height: 15, gapBefore: 20)
        alertsCheckbox.target = self
        alertsCheckbox.action = #selector(checkboxChanged(_:))
        append(alertsCheckbox, height: 20, gapBefore: 10)
        for control in profile.settingsAlertControls {
            switch control {
            case .quotaThreshold:
                appendSlider(thresholdLabel, thresholdSlider, height: 17, gapBefore: 8)
            case .resetLead:
                appendSlider(leadLabel, leadSlider, height: 17, gapBefore: 6)
            case .failureStreak:
                appendSlider(streakLabel, streakSlider, height: 17, gapBefore: 6)
            case .diskIO:
                appendSlider(diskLabel, diskSlider, height: 17, gapBefore: 6)
            case .walletTierNote:
                walletAlertNote.font = .systemFont(ofSize: 11)
                walletAlertNote.textColor = .secondaryLabelColor
                append(walletAlertNote, height: 32, gapBefore: 8)
            }
        }
    }

    /// 网络区：应用代理始终可配（出口探测 / Codex）；New API 另加「跟随」开关。
    private func buildNetworkRows() {
        let profile = config.profile
        append(heading("网络"), height: 15, gapBefore: 20)
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
        proxyHint.stringValue = profile.proxyHint
        content.addSubview(proxyHint)
        // 两行高度：提示文案较长，单行会被截断
        rows.append(Row(view: proxyHint, height: 30, gapBefore: 5, width: nil))
        if profile.capabilities.offersFollowAppProxy {
            followAppProxyCheckbox.target = self
            followAppProxyCheckbox.action = #selector(checkboxChanged(_:))
            append(followAppProxyCheckbox, height: 20, gapBefore: 8)
        }
    }

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
    private var monsterAppearanceButton: NSButton!

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
        monsterAppearanceButton.frame = NSRect(x: 144, y: 14, width: 190, height: 28)
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

    func updateConfig(_ value: Config) { config = value; refreshControls() }
    private var monsterSettings: MonsterSettingsController?
    @objc private func openMonsterAppearance() {
        monsterSettings = MonsterSettingsController(appearance: config.monster) { [weak self] value in
            guard let self else { return }
            var current = value
            current.enabled = self.config.monster.enabled
            self.config.setMonster(current)
            self.onChange(self.config)
        }
        monsterSettings?.show()
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
            proxyHint.stringValue = config.profile.proxyHint
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
        memoryCheckbox.state = config.showMemory ? .on : .off
        diskCheckbox.state = config.showDisk ? .on : .off
        alertsCheckbox.state = config.alertsEnabled ? .on : .off
        thresholdSlider.doubleValue = config.alertQuotaThreshold
        leadSlider.doubleValue = config.alertResetLeadMinutes
        streakSlider.doubleValue = config.alertFailureStreak
        diskSlider.doubleValue = config.diskAlertMBs
        proxyField.stringValue = config.proxyURL
        followAppProxyCheckbox.state = config.newAPIFollowAppProxy ? .on : .off
        // 选中段不设的话，分段控件会把两项画成同一副样子——看着像没生效。
        sourcePicker.selectedSegment = QuotaSource.allCases.firstIndex(of: config.quotaSource) ?? 0
        if proxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            proxyHint.stringValue = config.profile.proxyHint
            proxyHint.textColor = .secondaryLabelColor
        }
        refreshTokenState()
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
        // 预警关掉时阈值滑杆没有意义，置灰而不是隐藏——
        // 隐藏会让用户以为这个功能不存在。只处理当前 Profile 实际挂上的控件。
        let on = config.alertsEnabled
        let controls = Set(config.profile.settingsAlertControls)
        if controls.contains(.quotaThreshold) {
            thresholdSlider.isEnabled = on
            thresholdLabel.textColor = on ? .labelColor : .disabledControlTextColor
        }
        if controls.contains(.resetLead) {
            leadSlider.isEnabled = on
            leadLabel.textColor = on ? .labelColor : .disabledControlTextColor
        }
        if controls.contains(.failureStreak) {
            streakSlider.isEnabled = on
            streakLabel.textColor = on ? .labelColor : .disabledControlTextColor
        }
        if controls.contains(.diskIO) {
            diskSlider.isEnabled = on
            diskLabel.textColor = on ? .labelColor : .disabledControlTextColor
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
        } else if sender === memoryCheckbox {
            config.setShowMemory(sender.state == .on)
        } else if sender === diskCheckbox {
            config.setShowDisk(sender.state == .on)
        } else if sender === followAppProxyCheckbox {
            config.setNewAPIFollowAppProxy(sender.state == .on)
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
        if let appearance = renderAppearance {
            appearance.performAsCurrentDrawingAppearance {
                content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
        } else {
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
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
