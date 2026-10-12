import Foundation
import Security

/// macOS Keychain 读写。
///
/// 只依赖 Foundation 与 Security，不 import AppKit，因此可以在 `--self-test`
/// 里调用（Security 在无 NSApplication 的进程里可用）。
///
/// 为什么必须用 Keychain 而不是 UserDefaults：本项目的 `Config.proxyURL`
/// 明文存进 UserDefaults，代码注释写明前提是「本项目只代理 localhost，
/// 一般不含凭据」。New API 的账户访问令牌不满足这个前提——它是可读出
/// 账户余额的长期凭据，明文落在 plist 里既会被备份同步，也会出现在任何
/// 读取偏好设置的工具输出中。
enum KeychainStore {
    /// 读写失败时不抛错，返回 false / nil。
    ///
    /// UI 需要在用户保存设置时给出反馈，但读取失败通常意味着「没存过」
    /// 或「用户拒绝了访问」——这两种都不该让应用崩溃。调用方按需提示。
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // 先删后写：SecItemUpdate 在项不存在时返回 errSecItemNotFound，
        // 那种情况下退回 add，两条路径都覆盖到。
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // 令牌不进 iCloud 钥匙串，也不参与设备间同步——
            // 换机重新填一次比同步一份长期凭据更合理。
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 本应用使用的服务名与条目名。
    ///
    /// 单独列出来是因为删除凭据功能必须和服务名严格一致，
    /// 写成散落的字符串字面量早晚会对不上。
    enum Slot {
        static let service = "com.monsterpulse.newapi"
        /// New API **账户访问令牌**。
        ///
        /// 刻意与「模型调用 API Key」分开命名：调研实测两者是完全不同的
        /// 凭据体系，`middleware/auth.go` 的 UserAuth 接受账户 PAT 或控制台
        /// 访问令牌，而模型调用 Key 读不了账户接口（实测 401）。
        static let accountToken = "account-access-token"
    }
}