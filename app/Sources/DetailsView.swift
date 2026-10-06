import AppKit

// 详情窗口视图层。
//
// 从「一整块 NSTextField 拼字符串」改成结构化布局：每个额度窗口一行
// （标题 + 进度条 + 窗口长度/已用/重置倒计时），下面是 CPU 与内存两条
// 计量条，最下面是更新时间与状态提示。
//
// 布局全部手算 frame，不引 Auto Layout，与既有 DockView 的绘制风格一致；
// 高度由 preferredHeight 推出，窗口随之调整，避免内容被裁切。

// MARK: - 进度条

/// 圆角进度条。值不变时不重绘，避免无谓的 display() 调用。
final class BarView: NSView {
    /// 0...1，nil 表示无数据（只画底槽）
    var value: Double? {
        didSet { if value != oldValue { needsDisplay = true } }
    }
    var color: NSColor = .systemTeal {
        didSet { needsDisplay = true }
    }
    /// 条的厚度。内部可见，供同一文件的行视图对齐用。
    static let thickness: CGFloat = 7

    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.thickness / 2
        let track = NSRect(x: 0, y: (bounds.height - Self.thickness) / 2,
                           width: bounds.width, height: Self.thickness)
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard let value, value > 0 else { return }
        // 极小值也给一个可见的最小宽度，否则 1% 在 90pt 宽的槽里看不见
        let width = max(Self.thickness, bounds.width * min(1, max(0, value)))
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                         width: width, height: Self.thickness),
                     xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - 单个额度窗口

/// 一个额度窗口（如 5 小时 / 每周）占一行。
final class QuotaRowView: NSView {
    static let height: CGFloat = 52

    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let bar = BarView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        bar.color = .systemTeal
        meta.font = .systemFont(ofSize: 10.5)
        meta.textColor = .secondaryLabelColor
        addSubview(title); addSubview(bar); addSubview(meta)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title text: String, used: Int, remaining: Int, reset: String?) {
        title.stringValue = text
        bar.value = Double(remaining) / 100
        var parts = ["已用 \(used)% · 剩余 \(remaining)%"]
        if let reset { parts.append("重置 \(reset)") }
        meta.stringValue = parts.joined(separator: " · ")
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 0, y: bounds.height - 17, width: bounds.width, height: 17)
        bar.frame = NSRect(x: 0, y: bounds.height - 32, width: bounds.width, height: BarView.thickness)
        meta.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 14)
    }
}

// MARK: - CPU / 内存计量

/// 「名称 + 进度条 + 数值」一行。
final class MeterRowView: NSView {
    static let height: CGFloat = 18
    private static let nameWidth: CGFloat = 52
    private static let valueWidth: CGFloat = 40

    private let name = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let bar = BarView()

    init(name text: String, color: NSColor) {
        super.init(frame: .zero)
        name.stringValue = text
        name.font = .systemFont(ofSize: 11.5)
        value.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        value.alignment = .right
        bar.color = color
        addSubview(name); addSubview(bar); addSubview(value)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ fraction: Double?) {
        bar.value = fraction
        value.stringValue = fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    override func layout() {
        super.layout()
        name.frame = NSRect(x: 0, y: 1, width: Self.nameWidth, height: 15)
        value.frame = NSRect(x: bounds.width - Self.valueWidth, y: 1,
                             width: Self.valueWidth, height: 15)
        let barX = Self.nameWidth + 8
        bar.frame = NSRect(x: barX, y: (bounds.height - BarView.thickness) / 2,
                           width: bounds.width - barX - Self.valueWidth - 8,
                           height: BarView.thickness)
    }
}

/// 磁盘读入速率条。
///
/// 与 CPU/内存的比例条不同，磁盘速率没有天然的 0...1 上界（顺序读 SSD 可以到
/// 数千 MB/s），所以要按「相对量程」显示：满格代表 `fullScale` MB/s。这个量程
/// 取当前预警阈值的 4 倍，于是「预警线」落在条的 1/4 处，两者关系一眼可见。
/// 量程随配置变化是有意的——阈值调低，条随之更容易接近满格，符合直觉。
final class DiskRateRowView: NSView {
    static let height: CGFloat = 18
    private static let nameWidth: CGFloat = 52
    private static let valueWidth: CGFloat = 68

    private let name = NSTextField(labelWithString: "磁盘读入")
    private let value = NSTextField(labelWithString: "")
    private let bar = BarView()
    private var bytesPerSecond: Double?
    /// 满格对应的速率（字节/秒）。nil 表示按阈值推算。
    var fullScale: Double?

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 11.5)
        value.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        value.alignment = .right
        bar.color = .systemOrange
        addSubview(name); addSubview(bar); addSubview(value)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(rate: Double?) {
        bytesPerSecond = rate
        bar.value = rate.map { value in
            let scale = fullScale ?? 800 * 1_048_576
            guard scale > 0 else { return 0 }
            return min(1, value / scale)
        }
        value.stringValue = SystemFormat.rate(rate)
    }

    override func layout() {
        super.layout()
        name.frame = NSRect(x: 0, y: 1, width: Self.nameWidth, height: 15)
        value.frame = NSRect(x: bounds.width - Self.valueWidth, y: 1,
                             width: Self.valueWidth, height: 15)
        let barX = Self.nameWidth + 8
        bar.frame = NSRect(x: barX, y: (bounds.height - BarView.thickness) / 2,
                           width: bounds.width - barX - Self.valueWidth - 8,
                           height: BarView.thickness)
    }
}

// MARK: - 详情窗口主体

final class DetailsView: NSView {
    private enum Gap {
        static let afterHeader: CGFloat = 12
        static let betweenQuota: CGFloat = 16
        static let beforeDivider: CGFloat = 20
        static let afterDivider: CGFloat = 15
        static let betweenMeters: CGFloat = 8
        static let beforeFooter: CGFloat = 16
        static let beforeStatus: CGFloat = 7
        /// 明细行紧跟在其计量条下面，间距比其他计量行更紧
        static let detailGap: CGFloat = 3
    }

    private let header = NSTextField(labelWithString: "Codex 订阅额度")
    private let empty = NSTextField(labelWithString: "暂无额度数据")
    private let dividerOne = NSBox()
    private let dividerTwo = NSBox()
    private let footer = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let cpuRow = MeterRowView(name: "CPU", color: .systemTeal)
    private let memoryRow = MeterRowView(name: "内存", color: .systemPurple)
    private let diskRow = DiskRateRowView()
    /// 内存 / 压缩 / Swap 的文字明细，比一根条承载更多数字
    private let memoryDetail = NSTextField(labelWithString: "")
    private var quotaRows: [QuotaRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .secondaryLabelColor
        memoryDetail.font = .systemFont(ofSize: 10.5)
        memoryDetail.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 10.5)
        for box in [dividerOne, dividerTwo] {
            box.boxType = .separator
            addSubview(box)
        }
        for view in [header, empty, cpuRow, memoryRow, diskRow, memoryDetail, footer, status] {
            addSubview(view)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 结构化数据入口。AppDelegate 只负责取数与判断 stale，视图不含任何业务规则。
    func update(windows: [(title: String, used: Int, remaining: Int, reset: String?)],
                quotaAvailable: Bool, cpu: Double?, reading: SystemReading,
                showCPU: Bool, showMemory: Bool,
                updated: Date?, loading: Bool, errorText: String?, stale: Bool) {
        if quotaRows.count != windows.count {
            quotaRows.forEach { $0.removeFromSuperview() }
            quotaRows = windows.map { _ in
                let row = QuotaRowView(frame: .zero)
                addSubview(row)
                return row
            }
            // 新行要插在 dividerOne 之前，addSubview 会盖到分隔线
            for row in quotaRows { addSubview(row) }
        }
        for (row, item) in zip(quotaRows, windows) {
            row.update(title: item.title, used: item.used, remaining: item.remaining, reset: item.reset)
        }
        empty.isHidden = quotaAvailable
        // 被配置关掉的指标整行隐藏，而不是显示成「—」——关掉就是不想看
        cpuRow.isHidden = !showCPU
        cpuRow.update(showCPU ? cpu : nil)

        // 内存区从「一个占比数字」换成三行实测指标，因为占比看不出磁盘 I/O：
        // 跑本地大模型时最刺眼的是读权重的速率，而内存占比对此一无所知。
        memoryRow.isHidden = !showMemory
        diskRow.isHidden = !showMemory
        memoryDetail.isHidden = !showMemory
        if showMemory {
            memoryRow.update(reading.memoryFraction)
            diskRow.update(rate: reading.diskReadBytesPerSecond)
            // 已用内存 = 占比 × 总量。占比本身是近似口径，所以这里标「约」。
            let used = reading.memoryFraction.map { $0 * reading.physicalBytes }
            var parts = ["内存 \(SystemFormat.bytes(used)) / \(SystemFormat.bytes(reading.physicalBytes > 0 ? reading.physicalBytes : nil))"]
            if let compressed = reading.compressedBytes, compressed > 0 {
                parts.append("压缩 \(SystemFormat.bytes(compressed))")
            }
            if let swap = reading.swapUsedBytes, swap > 0 {
                parts.append("Swap \(SystemFormat.bytes(swap))")
            }
            memoryDetail.stringValue = parts.joined(separator: " · ")
        }

        let stamp = updated.map {
            "更新 " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium)
        } ?? "尚未获取额度"
        footer.stringValue = stamp

        // 状态行优先级：错误 > 过期 > 加载中。
        // 「旧数据，仅供参考」只在真的有快照时才说——首次查询就失败时根本
        // 没有旧数据，笼统说成旧数据会掩盖「这是完全不可用」这个事实
        // （产品原则：如实区分有效、过期与不可用）。
        var lines: [String] = []
        if let errorText { lines.append(errorText) }
        if stale && quotaAvailable { lines.append("旧数据，仅供参考") }
        if loading { lines.append("正在查询…") }
        status.stringValue = lines.joined(separator: "  ")
        status.textColor = errorText != nil ? .systemRed : (stale ? .systemOrange : .secondaryLabelColor)
        needsLayout = true
    }

    /// 内容总高度，供窗口按内容调整大小。
    var preferredHeight: CGFloat {
        var total: CGFloat = 17 + Gap.afterHeader          // header
        if quotaRows.isEmpty {
            total += 16
        } else {
            total += CGFloat(quotaRows.count) * QuotaRowView.height
            total += CGFloat(quotaRows.count - 1) * Gap.betweenQuota
            total += Gap.beforeDivider + 1 + Gap.afterDivider
        }
        // 被隐藏的计量行不占高度，也不出现在其前后的间隔里
        let meters = [cpuRow, memoryRow, diskRow].filter { !$0.isHidden }
        for (index, row) in meters.enumerated() {
            if index > 0 { total += Gap.betweenMeters }
            total += MeterRowView.height
        }
        if !meters.isEmpty { total += Gap.beforeDivider + 1 + Gap.afterDivider }
        if !memoryDetail.isHidden { total += Gap.detailGap + 13 }
        total += Gap.beforeFooter + 13
        if !status.stringValue.isEmpty { total += Gap.beforeStatus + statusSize.height }
        return total
    }

    private var statusSize: NSSize {
        let maxWidth = bounds.width > 0 ? bounds.width : 396
        let size = status.sizeThatFits(NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return NSSize(width: maxWidth, height: size.height)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 22
        let width = bounds.width - inset * 2
        // AppKit 原点在左下，从顶部往下量，最后统一翻转
        var cursor = bounds.height

        func place(_ view: NSView, _ height: CGFloat, gap: CGFloat) {
            cursor -= height
            view.frame = NSRect(x: inset, y: cursor, width: width, height: height)
            cursor -= gap
        }

        place(header, 17, gap: Gap.afterHeader)
        if quotaRows.isEmpty {
            place(empty, 16, gap: Gap.beforeDivider)
        } else {
            for (index, row) in quotaRows.enumerated() {
                let gap = index == quotaRows.count - 1 ? Gap.beforeDivider : Gap.betweenQuota
                place(row, QuotaRowView.height, gap: gap)
            }
            place(dividerOne, 1, gap: Gap.afterDivider)
        }
        let meters = [cpuRow, memoryRow, diskRow].filter { !$0.isHidden }
        for (index, row) in meters.enumerated() {
            let gap = index < meters.count - 1 ? Gap.betweenMeters : Gap.afterDivider
            place(row, MeterRowView.height, gap: gap)
        }
        if !meters.isEmpty { place(dividerTwo, 1, gap: Gap.beforeFooter) }
        if !memoryDetail.isHidden { place(memoryDetail, 13, gap: 0) }
        place(footer, 13, gap: Gap.beforeStatus)
        if !status.stringValue.isEmpty { place(status, statusSize.height, gap: 0) }
    }
}
