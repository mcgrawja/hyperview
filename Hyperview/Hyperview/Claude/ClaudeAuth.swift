//
//  ClaudeAuth.swift
//  Hyperview
//
//  Anthropic API key storage (Phase 5, §7.1: "key in Keychain"). Same pattern
//  as MailKeychain — the key never touches SwiftData, UserDefaults, or logs.
//

import Foundation
import Security

enum ClaudeAuth {
    private static let service = "com.mcgraw.Hyperview.claude"
    private static let account = "anthropic-api-key"
    /// Admin API key (sk-ant-admin01-…) for the Usage/Cost endpoints —
    /// distinct from the regular API key, org-level, read-only reporting.
    private static let adminAccount = "anthropic-admin-key"

    static func setAPIKey(_ key: String) {
        store(key, account: account)
    }

    static func apiKey() -> String? {
        read(account: account)
    }

    static func removeAPIKey() {
        setAPIKey("")
    }

    static func setAdminKey(_ key: String) {
        store(key, account: adminAccount)
    }

    static func adminKey() -> String? {
        read(account: adminAccount)
    }

    // MARK: - Keychain plumbing

    private static func store(_ key: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }
}
