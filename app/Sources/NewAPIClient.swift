import Foundation

/// New API 只读查询客户端。
///
/// 只依赖 Foundation，不 import AppKit。同步接口，配合既有的 BlockOperation
/// 在后台队列上调用（与 `CodexReader.read` 同一形态）。
///
/// 口径与字段来源见 `docs/new-api-research.md`，对应版本 v1.0.0-rc.25。
/// 全部是 GET，不调用任何写接口——特别注意 `GET /api/user/token`
/// 名字看着像只读，但 `GenerateAccessToken` 会**写入并替换**账户令牌，
/// 本客户端刻意不提供该路径。
struct NewAPIClient {
    let baseURL: URL
    let accessToken: String
    /// 独立于 Codex 的应用代理。留空表示直连。
    ///
    /// 不默认继承 Codex 代理：公司内网域名需要绕过代理，直接继承会把
    /// 请求送进代理导致连不通。新 API 的网络策略由设置页单独决定。
    let proxyURL: URL?
    let timeout: TimeInterval

    init(baseURL: URL, accessToken: String, proxyURL: URL? = nil, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.proxyURL = proxyURL
        self.timeout = timeout
    }

    /// 读取钱包摘要。站点配置、账户、近 24h 消耗、套餐四份数据合并成一个快照。
    ///
    /// 四者来自四个独立接口，缺一不可：
    /// - `/api/status` 提供换算参数，缺了只能显示原始 quota
    /// - `/api/user/self` 提供余额与累计消耗
    /// - `/api/data/self` 提供近 24h 消耗，是预计可用天数的分母
    /// - `/api/subscription/self` 提供套餐，有可信总额时才走百分比口径
    func fetchWallet(now: Date = Date(), cancelled: @escaping () -> Bool = { false }) throws -> NewAPI.Wallet {
        let statusJSON = try request(path: "/api/status", auth: false, cancelled: cancelled)
        let site = NewAPI.SiteConfig.parse(statusJSON)
        guard site.quotaPerUnit != nil || site.usdExchangeRate != nil else {
            throw ReadError.message(NewAPI.failureMessage(statusJSON) ?? "站点状态未返回计费配置")
        }
        let user = try request(path: "/api/user/self", auth: true, cancelled: cancelled)
        guard NewAPI.isSuccess(user) else {
            throw ReadError.message(NewAPI.failureMessage(user) ?? "账户信息读取失败；请检查访问令牌")
        }
        // 站点页面的近 24h 是「前 23 小时至后 1 小时」，与 /api/data/self 对齐。
        let window = NewAPI.recentWindow(now: now)
        let stats = try request(path: "/api/data/self?start_timestamp=\(window.start)&end_timestamp=\(window.end)&default_time=hour",
                                auth: true, cancelled: cancelled)
        guard NewAPI.isSuccess(stats) else {
            throw ReadError.message(NewAPI.failureMessage(stats) ?? "近期消耗读取失败")
        }
        // 套餐缺失不影响主流程：空数组表示无套餐，走钱包口径即可。
        let subs: [String: Any]? = try? request(path: "/api/subscription/self", auth: true, cancelled: cancelled)
        guard let wallet = NewAPI.Wallet.parse(userSelf: user, dataSelf: stats,
            subscriptionSelf: subs, site: site, fetchedAt: now) else {
            throw ReadError.message("账户响应缺少余额字段")
        }
        return wallet
    }

    /// 「检查连接」用的诊断信息。给设置页展示，不参与额度显示。
    struct Diagnostics: Equatable {
        var version: String
        var unitNote: String
        var balanceNote: String
        var hasSubscription: Bool
        var prosperity: NewAPI.Prosperity
    }

    /// 连通性检查。与 fetchWallet 相同的数据来源，额外强调换算依据，
    /// 让用户在填完地址和令牌后立刻看到服务端实际返回的口径。
    func checkConnection(cancelled: @escaping () -> Bool = { false }) throws -> Diagnostics {
        let wallet = try fetchWallet(cancelled: cancelled)
        // 站点配置缺失时明确说「按原始计费额度显示」，而不是显示一个
        // 看起来正常但其实是我们猜的金额。
        let unitNote = wallet.site.amount(forQuota: 500_000) == nil
            ? "站点未返回换算配置，金额将按原始计费额度显示"
            : "1 计费额度 = \(wallet.site.amount(forQuota: 500_000)!) \(wallet.site.displayType ?? "")"
        return Diagnostics(
            version: wallet.site.version ?? "未知",
            unitNote: unitNote,
            balanceNote: wallet.site.amount(forQuota: wallet.balance).map { "\(wallet.site.currencySymbol)\(String(format: "%.2f", $0))" }
                ?? "原始计费额度 \(wallet.balance)",
            hasSubscription: wallet.activeSubscription != nil,
            prosperity: wallet.prosperity)
    }

    // MARK: - 传输

    private func request(path: String, auth: Bool, cancelled: @escaping () -> Bool) throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ReadError.message("服务地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth {
            // 账户 PAT 走 Authorization，与模型调用 API Key 是两套凭据。
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        var configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // 凭据只在内存与 TLS 里，不落磁盘缓存。
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let proxyURL {
            configuration.connectionProxyDictionary = [
                "HTTPEnable": true, "HTTPProxy": proxyURL.host ?? "",
                "HTTPPort": proxyURL.port ?? 0, "HTTPSEnable": true,
                "HTTPSProxy": proxyURL.host ?? "", "HTTPSPort": proxyURL.port ?? 0,
            ]
        }

        var result: Result<[String: Any], Error>?
        var session: URLSession?
        let delegate = RedirectGuard()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session?.finishTasksAndInvalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        session!.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if cancelled() { result = .failure(ReadError.message("已取消")); return }
            if let error {
                result = .failure(ReadError.message("连接失败：\(error.localizedDescription)"))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // 401/403 单独提示——多数情况是令牌不对而不是服务不可用。
                if http.statusCode == 401 || http.statusCode == 403 {
                    result = .failure(ReadError.message("认证失败（HTTP \(http.statusCode)）：访问令牌无效或已过期"))
                } else {
                    result = .failure(ReadError.message("服务返回 HTTP \(http.statusCode)"))
                }
                return
            }
            guard let data, !data.isEmpty else {
                result = .failure(ReadError.message("服务返回空响应")); return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(ReadError.message("响应不是 JSON")); return
            }
            result = .success(json)
        }.resume()

        // 超时兜底：URLSession 自身也有超时，这里防的是连接建立在系统层面卡住。
        let deadline = Date().addingTimeInterval(timeout + 5)
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelled() || Date() > deadline {
                session?.invalidateAndCancel()
                result = .failure(ReadError.message("请求超时"))
                break
            }
        }
        guard let result else { throw ReadError.message("请求超时") }
        return try result.get()
    }

    /// 拒绝一切重定向。
    ///
    /// 调研明确记录过风险：New API 的部分路径有尾斜杠差异并返回 301。
    /// 跟随重定向本身没问题，但**跨 origin 跟随会把 Authorization 头一起带过去**
    /// ——凭据泄露只需要一次被劫持的重定向。所以这里一视同仁全部拒绝，
    /// 由调用方使用最终路径（调研已记录哪些路径带尾斜杠）。
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}