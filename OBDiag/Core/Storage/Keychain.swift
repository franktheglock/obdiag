import Foundation
import Security

/// Minimal Keychain wrapper for API keys. Secrets never enter UserDefaults or
/// any file the app writes.
enum Keychain {
    private static let service = "com.obdiag.app"

    enum Key: String {
        case openRouterAPIKey
        case tinyFishAPIKey
        case lmStudioAPIKey
    }

    static func set(_ value: String?, for key: Key) {
        guard let value, !value.isBlank else {
            delete(key)
            return
        }
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Masked representation for display, e.g. "sk-or-…9f2c".
    static func masked(_ value: String?) -> String {
        guard let value, !value.isBlank else { return "Not set" }
        guard value.count > 10 else { return "••••" }
        return "\(value.prefix(6))…\(value.suffix(4))"
    }
}
