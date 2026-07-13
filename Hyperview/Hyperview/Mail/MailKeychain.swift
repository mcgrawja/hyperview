//
//  MailKeychain.swift
//  Unifyr
//
//  App passwords never touch SwiftData/CloudKit (D9) or logs — they live in the
//  Keychain, keyed by account UUID, and ride iCloud Keychain across devices (see
//  SyncedKeychain). The account UUID is only shared between devices because
//  MailAccountSync makes them converge on one; without that, this lookup would
//  miss on every device but the one where the account was typed.
//

import Foundation

enum MailKeychain {
    private static let service = "com.mcgraw.Hyperview.mail"

    static func setPassword(_ password: String, for accountID: UUID) {
        SyncedKeychain.set(password, service: service, account: accountID.uuidString)
    }

    static func password(for accountID: UUID) -> String? {
        SyncedKeychain.read(service: service, account: accountID.uuidString)
    }

    static func deletePassword(for accountID: UUID) {
        SyncedKeychain.delete(service: service, account: accountID.uuidString)
    }

    /// Move a saved password when an account adopts the shared iCloud identity
    /// and its UUID changes (MailAccountSync.adopt).
    static func rekey(from old: UUID, to new: UUID) {
        guard old != new, let password = password(for: old) else { return }
        setPassword(password, for: new)
        deletePassword(for: old)
    }
}
