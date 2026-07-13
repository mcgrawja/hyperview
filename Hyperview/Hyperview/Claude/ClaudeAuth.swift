//
//  ClaudeAuth.swift
//  Hyperview
//
//  Anthropic API key storage (Phase 5, §7.1: "key in Keychain"). Same pattern
//  as MailKeychain — the key never touches SwiftData, UserDefaults, or logs.
//

import Foundation

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

    /// Both keys ride iCloud Keychain (SyncedKeychain), so they're entered once
    /// and are there on every device.
    private static func store(_ key: String, account: String) {
        SyncedKeychain.set(key, service: service, account: account)
    }

    private static func read(account: String) -> String? {
        SyncedKeychain.read(service: service, account: account)
    }
}
