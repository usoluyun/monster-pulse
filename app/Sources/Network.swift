import Foundation
import SystemConfiguration
import Darwin

/// 系统代理开关与探测请求的出口是两件事：PAC/分流/VPN 可让不同目标走不同出口。
/// 探测优先使用应用手填代理；留空时使用系统代理，不读取 shell 环境。
enum NetworkStatus {
    static func proxyEnabled(_ settings: [String: Any]?) -> Bool? {
        guard let settings else { return nil }
        return ["HTTPEnable", "HTTPSEnable", "SOCKSEnable",
                "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"].contains {
            (settings[$0] as? NSNumber)?.boolValue == true
        }
    }

    struct Exit: Equatable {
        let country: String
        let ip: String
    }

    static func parseTrace(_ text: String) -> Exit? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            fields[pair[0]] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard let country = fields["loc"], country != "XX",
              Locale.Region.isoRegions.contains(where: { $0.identifier == country }),
              let ip = fields["ip"] else { return nil }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        guard inet_pton(AF_INET, ip, &ipv4) == 1 || inet_pton(AF_INET6, ip, &ipv6) == 1 else { return nil }
        return Exit(country: country, ip: ip)
    }

    /// 短倒计时向上取整，避免还有 59 秒却显示「0m」。原始时间由额度窗口提供。
    static func resetLabel(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds.isFinite else { return nil }
        if seconds <= 0 { return "0m" }
        if seconds < 3600 { return "\(Int(ceil(seconds / 60)))m" }
        if seconds < 86400 { return "\(Int(ceil(seconds / 3600)))h" }
        return "\(Int(ceil(seconds / 86400)))d"
    }
}

/// 所有状态由主线程持有。复用系统采样计时器，每 5 分钟最多发一次小型 HTTPS 请求。
/// 代理配置变化时立即丢弃旧出口并重测；失败清空结果，60 秒后重试。
final class NetworkMonitor {
    private(set) var proxyEnabled: Bool?
    private(set) var exit: NetworkStatus.Exit?
    private(set) var updated: Date?
    private(set) var error: String?
    private(set) var loading = false
    private var configuredProxy: String?
    var probeProxyEnabled: Bool? { configuredProxy == nil ? proxyEnabled : true }
    var routeLabel: String { configuredProxy == nil ? "系统网络 / Cloudflare" : "应用代理 / Cloudflare" }
    private var process: Process?
    private var settings: NSDictionary?
    private var initialized = false
    private var nextProbe = Date.distantPast
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var generation = 0

    func poll(proxy: String? = nil, force: Bool = false, changed: @escaping () -> Void) {
        let current = SCDynamicStoreCopyProxies(nil) as? [String: Any]
        let dictionary = current.map { $0 as NSDictionary }
        let normalized = ProxySetting.normalize(proxy)
        let different = !initialized || dictionary != settings || normalized != configuredProxy
        if different {
            stop()
            initialized = true
            settings = dictionary
            configuredProxy = normalized
            proxyEnabled = NetworkStatus.proxyEnabled(current)
            exit = nil; updated = nil; error = nil
        }
        guard !loading, force || Date() >= nextProbe else { return }
        guard current != nil || normalized != nil else {
            error = "无法读取系统代理配置"; nextProbe = Date().addingTimeInterval(60)
            changed(); return
        }
        loading = true
        nextProbe = Date().addingTimeInterval(300)
        let token = generation
        if let normalized {
            // curl supports HTTP CONNECT, HTTPS and SOCKS URLs including authentication.
            // Explicit arguments override inherited proxy / NO_PROXY values; never fall back to direct.
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = Self.probeArguments(proxy: normalized)
            process.environment = ProcessInfo.processInfo.environment.filter {
                !["http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains($0.key.lowercased())
            }
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let result = process.terminationStatus == 0 && data.count <= 8192
                    ? String(data: data, encoding: .utf8).flatMap(NetworkStatus.parseTrace) : nil
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    self.process = nil
                    self.complete(result, changed: changed)
                }
            }
            self.process = process
            do { try process.run() }
            catch { self.process = nil; complete(nil, changed: changed) }
            changed()
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.connectionProxyDictionary = current
        let session = URLSession(configuration: config)
        self.session = session
        let request = URLRequest(url: URL(string: "https://cloudflare.com/cdn-cgi/trace")!)
        task = session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            let result: NetworkStatus.Exit?
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
               let data, data.count <= 8192, let text = String(data: data, encoding: .utf8) {
                result = NetworkStatus.parseTrace(text)
            } else { result = nil }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.task = nil; self.session = nil
                self.complete(result, changed: changed)
            }
        }
        task?.resume()
        changed()
    }

    static func probeArguments(proxy: String) -> [String] {
        ["--disable", "--silent", "--show-error", "--fail", "--max-time", "12",
         "--connect-timeout", "8", "--max-filesize", "8192", "--proxy", proxy,
         "--noproxy", "", "https://cloudflare.com/cdn-cgi/trace"]
    }

    private func complete(_ result: NetworkStatus.Exit?, changed: () -> Void) {
        loading = false
        exit = result
        updated = result == nil ? nil : Date()
        error = result == nil ? "出口探测失败，国家未知" : nil
        if result == nil { nextProbe = Date().addingTimeInterval(60) }
        changed()
    }

    func stop() {
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
        task?.cancel(); session?.invalidateAndCancel()
        task = nil; session = nil; loading = false
        nextProbe = .distantPast
        exit = nil; updated = nil
    }
}
