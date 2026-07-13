//
//  MailAccountSync.swift
//  Unifyr
//
//  Syncs mail ACCOUNT CONFIG across devices — an amendment to D9, not a reversal
//  of it. The mail cache (mailboxes, messages, bodies, attachments) stays local
//  and server-authoritative; it still never enters iCloud. What travels here is
//  the handful of fields you'd otherwise retype on every device: address, hosts,
//  ports, signature, badge.
//
//  Why it's required for password sync at all: the app password is stored in the
//  Keychain under the account's UUID, and that UUID is minted on whichever device
//  you typed the account into. Sync the password alone and the iPhone would mint
//  its own UUID for the same address and look up a secret that doesn't exist
//  there. So both devices must converge on ONE UUID per address — that's the job
//  of `adopt` below, and it's the whole reason this file exists.
//
//  Transport is iCloud's key-value store: a few hundred bytes, no CloudKit
//  schema to deploy, no message content. Conflicts resolve last-write-wins on
//  `updatedAt`; deletions leave tombstones so a removed account isn't
//  resurrected by the other device's copy.
//

import Foundation
import SwiftData

@MainActor
final class MailAccountSync {
    static let shared = MailAccountSync()

    private let store = NSUbiquitousKeyValueStore.default
    private static let storeKey = "mail.accounts.v1"

    private var context: ModelContext?

    // MARK: - Wire format

    private struct Payload: Codable {
        var accounts: [Record] = []
        var tombstones: [Tombstone] = []
    }

    private struct Record: Codable {
        var id: UUID
        var email: String
        var displayName: String
        var imapHost: String
        var imapPort: Int
        var smtpHost: String
        var smtpPort: Int
        var signature: String
        var badgeLabel: String
        var badgeColorHex: String
        var updatedAt: Date
    }

    private struct Tombstone: Codable {
        var email: String
        var deletedAt: Date
    }

    // MARK: - Lifecycle

    /// Reconcile at launch, then again whenever another device writes.
    func start(context: ModelContext) {
        self.context = context

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }

        store.synchronize()
        sync()
    }

    /// Publish local edits. Call after adding or editing an account.
    func push() {
        sync()
    }

    /// Record a deletion so the other devices drop the account too, instead of
    /// pushing it straight back at us on their next sync.
    func recordDeletion(email: String) {
        var payload = remote()
        let key = Self.normalize(email)
        payload.accounts.removeAll { Self.normalize($0.email) == key }
        payload.tombstones.removeAll { Self.normalize($0.email) == key }
        payload.tombstones.append(Tombstone(email: email, deletedAt: Date()))
        write(payload)
    }

    // MARK: - Reconciliation

    /// Merge remote into local and local into remote, in that order, so the two
    /// converge no matter which device saw the change first.
    private func sync() {
        guard let context else { return }

        var payload = remote()
        var localChanged = false
        var remoteChanged = false

        var byEmail: [String: MailAccount] = [:]
        for account in (try? context.fetch(FetchDescriptor<MailAccount>())) ?? [] {
            byEmail[Self.normalize(account.emailAddress)] = account
        }

        // 1. Deletions from another device — but only if we haven't edited the
        //    account since it was deleted there.
        for tombstone in payload.tombstones {
            let key = Self.normalize(tombstone.email)
            guard let local = byEmail[key], local.updatedAt <= tombstone.deletedAt else { continue }
            purge(local, in: context)
            byEmail[key] = nil
            localChanged = true
        }

        // 2. Remote accounts land locally, adopting the shared UUID.
        for record in payload.accounts {
            let key = Self.normalize(record.email)
            let deletedLater = payload.tombstones.contains {
                Self.normalize($0.email) == key && $0.deletedAt > record.updatedAt
            }
            if deletedLater { continue }

            guard let local = byEmail[key] else {
                let account = MailAccount()
                apply(record, to: account)
                context.insert(account)
                byEmail[key] = account
                localChanged = true
                continue
            }

            if local.id != record.id {
                adopt(record.id, for: local, in: context)
                localChanged = true
            }
            if record.updatedAt > local.updatedAt {
                apply(record, to: local)
                localChanged = true
            } else if record.updatedAt < local.updatedAt {
                remoteChanged = true
            }
        }

        // 3. Local accounts (new ones, and edits newer than the remote copy) go up.
        for account in byEmail.values {
            if let index = payload.accounts.firstIndex(where: { $0.id == account.id }) {
                if account.updatedAt > payload.accounts[index].updatedAt {
                    payload.accounts[index] = record(for: account)
                    remoteChanged = true
                }
            } else {
                payload.accounts.append(record(for: account))
                remoteChanged = true
            }
            // An account we still hold is a live one: clear any stale tombstone
            // so it isn't purged on the next pass.
            let key = Self.normalize(account.emailAddress)
            let stale = payload.tombstones.filter {
                Self.normalize($0.email) == key && $0.deletedAt < account.updatedAt
            }
            if !stale.isEmpty {
                payload.tombstones.removeAll { Self.normalize($0.email) == key && $0.deletedAt < account.updatedAt }
                remoteChanged = true
            }
        }

        if localChanged { try? context.save() }
        if remoteChanged { write(payload) }
    }

    /// Re-home an account onto the UUID the other devices already use. The
    /// cache rows key off `accountID`, and the Keychain password keys off the
    /// UUID, so both have to move with it.
    private func adopt(_ newID: UUID, for account: MailAccount, in context: ModelContext) {
        let oldID = account.id
        MailLog.log("[AccountSync] \(account.emailAddress) adopting shared id \(newID) (was \(oldID))")
        MailKeychain.rekey(from: oldID, to: newID)

        for box in (try? context.fetch(FetchDescriptor<Mailbox>())) ?? [] where box.accountID == oldID {
            box.accountID = newID
        }
        for message in (try? context.fetch(FetchDescriptor<MailMessage>())) ?? [] where message.accountID == oldID {
            message.accountID = newID
        }
        account.id = newID
    }

    /// Drop an account and everything cached for it (mirrors MailService.removeAccount,
    /// minus the live-connection teardown, which the caller there handles).
    private func purge(_ account: MailAccount, in context: ModelContext) {
        MailLog.log("[AccountSync] removing \(account.emailAddress) — deleted on another device")
        let id = account.id
        MailKeychain.deletePassword(for: id)
        for message in (try? context.fetch(FetchDescriptor<MailMessage>())) ?? [] where message.accountID == id {
            context.delete(message)
        }
        for box in (try? context.fetch(FetchDescriptor<Mailbox>())) ?? [] where box.accountID == id {
            context.delete(box)
        }
        context.delete(account)
    }

    // MARK: - Mapping

    private func apply(_ record: Record, to account: MailAccount) {
        account.id = record.id
        account.emailAddress = record.email
        account.displayName = record.displayName
        account.imapHost = record.imapHost
        account.imapPort = record.imapPort
        account.smtpHost = record.smtpHost
        account.smtpPort = record.smtpPort
        account.signature = record.signature
        account.badgeLabel = record.badgeLabel
        account.badgeColorHex = record.badgeColorHex
        account.updatedAt = record.updatedAt
    }

    private func record(for account: MailAccount) -> Record {
        Record(
            id: account.id,
            email: account.emailAddress,
            displayName: account.displayName,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            smtpHost: account.smtpHost,
            smtpPort: account.smtpPort,
            signature: account.signature,
            badgeLabel: account.badgeLabel,
            badgeColorHex: account.badgeColorHex,
            updatedAt: account.updatedAt
        )
    }

    // MARK: - Store

    private func remote() -> Payload {
        guard let data = store.data(forKey: Self.storeKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Payload()
        }
        return payload
    }

    private func write(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        store.set(data, forKey: Self.storeKey)
        store.synchronize()
        MailLog.log("[AccountSync] published \(payload.accounts.count) account(s), \(payload.tombstones.count) tombstone(s)")
    }

    private static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
