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
}

final class SystemSampler {
    private let host = mach_host_self()
    private var previous: [UInt32]?
    deinit { mach_port_deallocate(mach_task_self_, host) }
    func sample() -> (cpu: Double?, memory: Double?) {
        var cpu = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuStatus = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        var load: Double?
        if cpuStatus == KERN_SUCCESS {
            let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
            if let old = previous {
                let delta = zip(ticks, old).map { Double($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 { load = (total - delta[Int(CPU_STATE_IDLE)]) / total }
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
        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(host, &pageSize)
        var memory: Double?
        if vmStatus == KERN_SUCCESS && pageStatus == KERN_SUCCESS {
            // Approximation: active + wired + compressed physical pages; not memory pressure.
            let pages = Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)
            memory = min(1, max(0, pages * Double(pageSize) / Double(ProcessInfo.processInfo.physicalMemory)))
        }
        return (load, memory)
    }
    func reset() { previous = nil }
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
