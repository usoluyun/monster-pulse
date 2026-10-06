import Foundation
import Darwin

struct QuotaWindow {
    let used: Double
    let minutes: Int?
    let resetsAt: Date?
    var remaining: Int { Int((100 - used).rounded()) }
}

struct Quota {
    let windows: [QuotaWindow]
    // Never substitute another product's quota when a multi-bucket response exists.
    static func parse(_ result: [String: Any]) throws -> Quota {
        let bucket: [String: Any]?
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any], !buckets.isEmpty {
            bucket = buckets["codex"] as? [String: Any]
        } else {
            let legacy = result["rateLimits"] as? [String: Any]
            let id = legacy?["limitId"] as? String
            bucket = (id == nil || id == "codex") ? legacy : nil
        }
        let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
            guard let item = bucket?[key] as? [String: Any],
                  let used = item["usedPercent"] as? Double,
                  used.isFinite, (0...100).contains(used) else { return nil }
            return QuotaWindow(used: used, minutes: item["windowDurationMins"] as? Int,
                resetsAt: (item["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
        guard !windows.isEmpty else { throw ReadError.message("账户未返回可用的 Codex 额度") }
        return Quota(windows: windows)
    }
}

/// 内存与磁盘相关数值的人话格式化。
///
/// 放在领域层而非展示层：详情窗口、Dock 菜单、预警文案都要用同一套写法，
/// 且这些是纯函数，可以在 --self-test 里断言（AppKit 起来之前就能跑）。
enum SystemFormat {
    /// 字节数 → 「12.4 GB」/「860 MB」。用 1024 进制并保留一位小数。
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let gb = value / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = value / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", value / 1024)
    }

    /// 速率 → 「450 MB/s」/「1.2 GB/s」。低速时不显示成 0.0 MB/s。
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value.isFinite, value >= 0 else { return "—" }
        if value < 1024 { return String(format: "%.0f KB/s", value / 1024) }
        let mb = value / 1_048_576
        if mb < 1000 { return String(format: "%.0f MB/s", mb) }
        return String(format: "%.1f GB/s", value / 1_073_741_824)
    }

    /// 百分比，nil 显示为破折号
    static func percent(_ fraction: Double?) -> String {
        guard let value = fraction, value.isFinite else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }
}

enum ReadError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// 额度相关文本的格式化。
///
/// 放在这里而不是 DetailsView 里：详情窗口、Dock 菜单、预警逻辑三处都要用，
/// 属于领域层而非展示层。Metrics.swift 只依赖 Foundation，自检可在
/// 创建 AppKit 应用之前调用。
enum QuotaFormat {
    /// 由服务返回的窗口长度推导标题，不硬编码「五小时」「每周」——
    /// 窗口长度以服务返回为准（见 docs/codex-dock-feasibility.md §数据来源）。
    static func windowTitle(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "额度窗口" }
        for (unit, size) in [("周", 10_080), ("天", 1_440), ("小时", 60)] {
            if minutes % size == 0 { return "\(minutes / size) \(unit)窗口" }
        }
        return "\(minutes) 分钟窗口"
    }

    /// 重置倒计时。文案避免「0 分后」这类难读输出。
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "已到期" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        let (days, restHours) = (hours / 24, hours % 24)
        if days > 0 { return restHours > 0 ? "\(days) 天 \(restHours) 小时后" : "\(days) 天后" }
        if hours > 0 { return rest > 0 ? "\(hours) 小时 \(rest) 分后" : "\(hours) 小时后" }
        return "\(minutes) 分后"
    }

    /// 窗口已过去的比例，0...1。
    ///
    /// 用来在进度条上标出「按时间进度本应消耗多少」，与实际用量对比即可一眼
    /// 看出是超前还是落后于时间——比单看剩余百分比有用得多。
    ///
    /// 返回 nil 只在数据不可信时发生：缺窗口长度，或 `resetsAt` 距现在比整个
    /// 窗口还远（两者不自洽，可能是时钟偏移或陈旧数据，画出来的位置会是假的）。
    ///
    /// 边界值的处理是有意的：`elapsed == 0`（刚进入窗口）返回 0.0 而非 nil——
    /// 0% 是合法进度，参考线该画在左端；已过期则夹到 1.0，表示时间已全部用尽。
    static func windowProgress(resetsAt: Date, windowMinutes: Int, now: Date = Date()) -> Double? {
        guard windowMinutes > 0 else { return nil }
        let total = Double(windowMinutes) * 60
        let elapsed = total - resetsAt.timeIntervalSince(now)
        guard elapsed >= 0 else { return nil }
        return min(1, max(0, elapsed / total))
    }
}

/// 一次系统采样。字段缺失表示读不到（如首次采样没有差值基准）。
struct SystemReading {
    /// CPU 忙碌率 0...1。注意时效性：底层 tick 计数器约每秒才刷新，
    /// 短于 1 秒的采样大概率拿不到值。
    var cpu: Double?
    /// (active + wired + compressed) / 物理内存的近似占比。**不是内存压力**，
    /// 也不等于活动监视器的「内存已使用」，更看不到磁盘 I/O。
    var memoryFraction: Double?
    /// 压缩内存字节数
    var compressedBytes: Double?
    /// 从磁盘读入速率（字节/秒）
    var diskReadBytesPerSecond: Double?
    /// 换出到磁盘速率（字节/秒）
    var diskWriteBytesPerSecond: Double?
    /// swap 已用字节数
    var swapUsedBytes: Double?
    /// 物理内存总量
    var physicalBytes: Double = 0
}

final class SystemSampler {
    private let host = mach_host_self()
    private var previous: [UInt32]?
    /// pageins/pageouts 是累计计数器，速率靠相邻差值，所以要留住上一次的值。
    /// 与 CPU tick 不同：这两个是亚秒级更新的（实测 0.2s 窗口内就有增量），
    /// 而 CPU tick 约每秒才刷新一次。
    private var previousPageIns: UInt64?
    private var previousPageOuts: UInt64?
    private var previousPageSample: TimeInterval?

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func sample() -> SystemReading {
        var reading = SystemReading()
        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(host, &pageSize)

        var cpu = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuStatus = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if cpuStatus == KERN_SUCCESS {
            let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
            if let old = previous {
                let delta = zip(ticks, old).map { Double($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 { reading.cpu = (total - delta[Int(CPU_STATE_IDLE)]) / total }
            }
            previous = ticks
        }

        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmStatus == KERN_SUCCESS, pageStatus == KERN_SUCCESS {
            let page = Double(pageSize)
            let pages = Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)
            reading.memoryFraction = min(1, max(0, pages * page / Double(ProcessInfo.processInfo.physicalMemory)))
            reading.compressedBytes = Double(vm.compressor_page_count) * page

            // 磁盘 I/O 速率。实测读 684MB 文件时，pageins 增量换算出的速率与实际
            // 读取速率一致（4489 vs 4493 MB/s），所以这是可信的实时度量。
            // pageins/pageouts 是 natural_t（UInt32）会回绕，用 &- 做无符号差。
            let now = ProcessInfo.processInfo.systemUptime
            if let oldIn = previousPageIns, let oldOut = previousPageOuts, let oldAt = previousPageSample {
                let elapsed = now - oldAt
                if elapsed > 0 {
                    reading.diskReadBytesPerSecond =
                        Double(UInt64(vm.pageins) &- oldIn) * page / elapsed
                    reading.diskWriteBytesPerSecond =
                        Double(UInt64(vm.pageouts) &- oldOut) * page / elapsed
                }
            }
            previousPageIns = UInt64(vm.pageins)
            previousPageOuts = UInt64(vm.pageouts)
            previousPageSample = now
        }

        reading.swapUsedBytes = Self.swapUsedBytes()
        reading.physicalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        return reading
    }

    /// swap 已用字节数。直接调 sysctlbyname，**不 spawn `sysctl` 进程**——
    /// 项目原则禁止为采集常规指标启动子进程。
    private static func swapUsedBytes() -> Double? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Double(usage.xsu_used)
    }

    /// 唤醒后调用：清空全部差值基准，否则跨越睡眠的那段会被算成一个巨大的速率。
    func reset() {
        previous = nil
        previousPageIns = nil
        previousPageOuts = nil
        previousPageSample = nil
    }
}

enum CodexReader {
    static func executable() throws -> String {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = env["CODEX_BIN"].map { [$0] } ??
            ((env["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" } +
             ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"])
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ReadError.message("找不到 Codex CLI；请安装，或设置 CODEX_BIN 为绝对路径")
        }
        return path
    }

    static func read(cancelled: () -> Bool = { false }) throws -> Quota {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try executable())
        process.arguments = ["app-server"]
        // Neutral working directory; no thread/start, inference, or project operations.
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let end = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
            "name": "monster_pulse", "version": "1.0.0"]]])
        var pending = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline && !cancelled() {
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let size = Darwin.read(fd.fd, &bytes, bytes.count)
            if size <= 0 { break }
            pending.append(contentsOf: bytes.prefix(size))
            guard pending.count < 1_048_576 else { throw ReadError.message("Codex 响应超出大小限制") }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if message["error"] != nil {
                    throw ReadError.message("Codex 查询失败；请在终端确认 codex login status 和网络连接")
                }
                if id == 1 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                } else if id == 2, let result = message["result"] as? [String: Any] {
                    return try Quota.parse(result)
                }
            }
        }
        throw ReadError.message(cancelled() ? "查询已取消" : "Codex 查询超时或进程退出；请检查 CLI 登录状态和网络")
    }
}
