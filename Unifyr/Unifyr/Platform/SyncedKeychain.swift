//
//  SyncedKeychain.swift
//  Unifyr
//
//  Generic-password storage that rides iCloud Keychain, so a secret typed on one
//  device turns up on the others (end-to-end encrypted — Apple can't read it).
//
//  Two platform facts shape this file:
//
//  1. `kSecAttrSynchronizable` only exists in the *data protection* keychain. On
//     iOS that's the only keychain there is. On macOS the default is the legacy
//     file-based keychain, which cannot sync at all — so macOS queries opt into
//     the modern one with `kSecUseDataProtectionKeychain`. That in turn requires
//     the app be signed with a keychain access group (see the entitlements).
//  2. Those are two separate stores. Secrets written before this change are
//     invisible to the synced queries, so `read` falls back to the legacy store
//     and migrates the secret up on the way through — nobody retypes anything.
//

import Foundation
import Security

enum SyncedKeychain {
    /// Write a secret to the synced keychain. An empty value just clears it.
    static func set(_ value: String, service: String, account: String) {
        // Clear BOTH stores so a stale legacy copy can't shadow the new value.
        delete(service: service, account: account)
        guard !value.isEmpty else { return }

        let status = add(value, service: service, account: account, synced: true)
        guard status != errSecSuccess else { return }

        // The synced keychain needs a keychain-access-group entitlement. If the
        // build isn't signed for it, keep the secret device-locally rather than
        // silently dropping it on the floor.
        MailLog.log("[Keychain] synced write failed (OSStatus \(status)) for \(service) — falling back to local storage")
        _ = add(value, service: service, account: account, synced: false)
    }

    /// Read a secret, migrating a pre-sync (device-local) one up to iCloud.
    static func read(service: String, account: String) -> String? {
        if let value = copy(service: service, account: account, synced: true) {
            // Drop any pre-sync duplicate so a stale secret isn't left behind in
            // the local keychain. A no-op once it's gone.
            SecItemDelete(query(service: service, account: account, synced: false) as CFDictionary)
            return value
        }
        guard let legacy = copy(service: service, account: account, synced: false) else { return nil }
        MailLog.log("[Keychain] migrating local secret for \(service) into iCloud Keychain")
        set(legacy, service: service, account: account)
        return legacy
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account, synced: true) as CFDictionary)
        SecItemDelete(query(service: service, account: account, synced: false) as CFDictionary)
    }

    // MARK: - Plumbing

    private static func add(_ value: String, service: String, account: String, synced: Bool) -> OSStatus {
        var item = query(service: service, account: account, synced: synced)
        item[kSecValueData as String] = Data(value.utf8)
        // afterFirstUnlock: the mail poller and notification tick run while the
        // device is locked, and they need the password.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil)
    }

    private static func copy(service: String, account: String, synced: Bool) -> String? {
        var item = query(service: service, account: account, synced: synced)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    private static func query(service: String, account: String, synced: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        // On macOS the STORE is chosen by this flag alone: with it, the data
        // protection keychain (the only one that can sync); without it, the
        // legacy file-based keychain. Don't also pass kSecAttrSynchronizable
        // here — it's a data-protection concept, and the file keychain handles
        // it inconsistently (a delete keyed on it can silently match nothing,
        // stranding the old copy behind).
        if synced {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = true
        }
        #else
        // iOS has one keychain, so the attribute itself is the distinction.
        query[kSecAttrSynchronizable as String] = synced
        #endif
        return query
    }
}
