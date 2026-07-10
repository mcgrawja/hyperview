//
//  MailService.swift
//  Hyperview
//
//  The mail orchestration layer for the UI (Phase 4), analogous to NotesStore.
//  It drives the IMAP/SMTP actors (which do the networking + parsing off the
//  main actor) and upserts Sendable results into the local, non-CloudKit cache
//  on the main actor. The MCP-facing MailBroker (Phase 6, §7) will wrap the same
//  operations.
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailService {
    enum Status: Equatable {
        case idle, connecting, connected, syncing
        case error(String)
    }

    var status: Status = .idle

    /// Persistent per-account failures (e.g. bad credentials). Unlike `status`,
    /// these are NOT overwritten by another account's success — they stay until
    /// the failing account connects.
    var accountErrors: [UUID: String] = [:]

    @ObservationIgnored var context: ModelContext?
    /// One live IMAP connection per account.
    @ObservationIgnored private var clients: [UUID: IMAPClient] = [:]

    // MARK: Connection

    func connect(_ account: MailAccount) async {
        guard clients[account.id] == nil else { return }
        guard var password = MailKeychain.password(for: account.id) else {
            status = .error("No saved password for \(account.emailAddress).")
            return
        }
        // Heal stored app passwords that were saved with display whitespace
        // (Google shows them as "xxxx xxxx xxxx xxxx"; the separators are often
        // non-breaking spaces). If removing all whitespace yields the canonical
        // 16-lowercase-letter shape, use — and persist — the condensed form.
        let condensed = String(password.filter { !$0.isWhitespace })
        if condensed != password, condensed.count == 16,
           condensed.allSatisfy({ $0.isLetter && $0.isLowercase }) {
            MailLog.log("[Mail] healing stored app password for \(account.emailAddress) (was \(password.count) chars with whitespace)")
            password = condensed
            MailKeychain.setPassword(condensed, for: account.id)
        }
        status = .connecting
        let config = MailServerConfig(host: account.imapHost, port: account.imapPort, username: account.emailAddress)
        let client = IMAPClient(config: config)
        do {
            // Password METADATA only (shape debugging) — never the content.
            let hasWhitespace = password.contains(where: \.isWhitespace)
            MailLog.log("[Mail] connecting \(account.imapHost):\(account.imapPort) as \(account.emailAddress) (pw: \(password.count) chars\(hasWhitespace ? ", CONTAINS WHITESPACE" : ""))")
            try await client.connect()
            try await client.login(password: password)
            clients[account.id] = client
            status = .connected
            accountErrors[account.id] = nil
            MailLog.log("[Mail] login OK (\(account.emailAddress))")
            await syncMailboxes(account)
        } catch {
            MailLog.log("[Mail] connect/login error (\(account.emailAddress)): \(error)")
            status = .error("\(account.emailAddress): \(describe(error))")
            accountErrors[account.id] = "\(account.emailAddress): \(describe(error))"
        }
    }

    func disconnect(_ account: MailAccount) async {
        if let client = clients.removeValue(forKey: account.id) {
            await client.logout()
        }
    }

    private func ensureConnected(_ account: MailAccount) async -> IMAPClient? {
        if let client = clients[account.id] { return client }
        await connect(account)
        return clients[account.id]
    }

    // MARK: Sync

    /// LIST only — deliberately fast. Per-mailbox counts are fetched lazily when
    /// a mailbox is opened (see `syncMessages`), so the inbox loads immediately
    /// instead of waiting on a STATUS for every folder.
    func syncMailboxes(_ account: MailAccount) async {
        guard let context, let imap = await ensureConnected(account) else { return }
        do {
            let infos = try await imap.listMailboxes()
            MailLog.log("[Mail] listMailboxes -> \(infos.count) mailboxes")
            upsertMailboxes(infos, accountID: account.id, in: context)
            try? context.save()
        } catch {
            MailLog.log("[Mail] listMailboxes error: \(error)")
            failed(account, error)
        }
    }

    func syncMessages(_ account: MailAccount, mailboxPath: String, limit: Int = 50, quiet: Bool = false) async {
        guard let context, let imap = await ensureConnected(account) else { return }
        if !quiet { status = .syncing }
        do {
            let summaries = try await imap.fetchSummaries(path: mailboxPath, limit: limit)
            MailLog.log("[Mail] fetchSummaries \(mailboxPath) -> \(summaries.count) messages")
            let arrived = upsertMessages(summaries, accountID: account.id, mailboxPath: mailboxPath, in: context)
            if mailboxPath.uppercased() == "INBOX" {
                await applyRules(to: arrived, account: account, in: context)
            }
            // Update just this mailbox's badge (cheap, one round trip).
            let counts = await imap.status(mailboxPath)
            updateCounts(mailboxPath: mailboxPath, accountID: account.id, counts: counts, in: context)
            try? context.save()
            if !quiet { status = .connected }
        } catch {
            MailLog.log("[Mail] syncMessages error: \(error)")
            if quiet {
                // Background tick: drop the connection to reconnect next tick,
                // but don't surface a scary banner for a transient blip.
                clients[account.id] = nil
            } else {
                failed(account, error)
            }
        }
    }

    // MARK: Auto-refresh

    /// Background inbox sync for every account (also triggers rules on new
    /// arrivals). Timer-based v1; IMAP IDLE is a future upgrade.
    func startAutoRefresh(every interval: TimeInterval = 300) {
        guard autoRefreshTask == nil else { return }
        MailLog.log("[Mail] auto-refresh every \(Int(interval))s")
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.syncAllInboxes()
            }
        }
    }

    func syncAllInboxes() async {
        guard let context else { return }
        let accounts = (try? context.fetch(FetchDescriptor<MailAccount>())) ?? []
        for account in accounts {
            await syncMessages(account, mailboxPath: "INBOX", quiet: true)
        }
    }

    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    private func updateCounts(mailboxPath: String, accountID: UUID, counts: (total: Int, unread: Int), in context: ModelContext) {
        let boxes = (try? context.fetch(FetchDescriptor<Mailbox>())) ?? []
        if let box = boxes.first(where: { $0.accountID == accountID && $0.path == mailboxPath }) {
            box.totalCount = counts.total
            box.unreadCount = counts.unread
        }
    }

    /// On a network error, drop that account's connection so the next action
    /// reconnects.
    private func failed(_ account: MailAccount, _ error: Error) {
        clients[account.id] = nil
        status = .error("\(account.emailAddress): \(describe(error))")
        accountErrors[account.id] = "\(account.emailAddress): \(describe(error))"
    }

    /// Remove an account entirely: connection, cached data, keychain secret.
    func removeAccount(_ account: MailAccount) async {
        await disconnect(account)
        accountErrors[account.id] = nil
        MailKeychain.deletePassword(for: account.id)
        if let context {
            let accountID = account.id
            let messages = (try? context.fetch(FetchDescriptor<MailMessage>())) ?? []
            for message in messages where message.accountID == accountID { context.delete(message) }
            let boxes = (try? context.fetch(FetchDescriptor<Mailbox>())) ?? []
            for box in boxes where box.accountID == accountID { context.delete(box) }
            context.delete(account)
            try? context.save()
        }
    }

    func search(_ account: MailAccount, mailboxPath: String, query: String, limit: Int = 50) async {
        guard let context, let imap = await ensureConnected(account) else { return }
        do {
            let summaries = try await imap.search(path: mailboxPath, query: query, limit: limit)
            upsertMessages(summaries, accountID: account.id, mailboxPath: mailboxPath, in: context)
            try? context.save()
        } catch {
            failed(account, error)
        }
    }

    func loadBody(_ message: MailMessage, account: MailAccount) async {
        guard let context, let imap = await ensureConnected(account) else { return }
        do {
            let body = try await imap.fetchBody(path: message.mailboxPath, uid: message.uid)
            message.bodyText = body.text
            message.bodyHTML = body.html
            message.hasFetchedBody = true
            // Replace cached attachments with the freshly decoded set.
            let messageID = message.id
            let stale = (try? context.fetch(FetchDescriptor<MailAttachment>())) ?? []
            for attachment in stale where attachment.messageID == messageID {
                context.delete(attachment)
            }
            for part in body.attachments {
                context.insert(MailAttachment(
                    messageID: messageID,
                    filename: part.filename,
                    mimeType: part.mimeType,
                    contentID: part.contentID,
                    data: part.data
                ))
            }
            if !message.isSeen {
                try? await imap.markSeen(path: message.mailboxPath, uid: message.uid)
                message.isSeen = true
            }
            try? context.save()
        } catch {
            failed(account, error)
        }
    }

    // MARK: Message actions

    func setSeen(_ message: MailMessage, account: MailAccount, seen: Bool) async {
        guard let imap = await ensureConnected(account) else { return }
        do {
            try await imap.setFlag(path: message.mailboxPath, uid: message.uid, flag: "\\Seen", on: seen)
            message.isSeen = seen
            try? context?.save()
        } catch { failed(account, error) }
    }

    func setFlagged(_ message: MailMessage, account: MailAccount, flagged: Bool) async {
        guard let imap = await ensureConnected(account) else { return }
        do {
            try await imap.setFlag(path: message.mailboxPath, uid: message.uid, flag: "\\Flagged", on: flagged)
            message.isFlagged = flagged
            try? context?.save()
        } catch { failed(account, error) }
    }

    /// Delete = move to the account's trash mailbox (server-side), then drop the
    /// cached row.
    func delete(_ message: MailMessage, account: MailAccount) async {
        await move(message, account: account, to: trashPath(for: account))
    }

    func move(_ message: MailMessage, account: MailAccount, to destination: String) async {
        guard destination != message.mailboxPath else { return }
        guard let context, let imap = await ensureConnected(account) else { return }
        do {
            try await imap.move(path: message.mailboxPath, uid: message.uid, to: destination)
            // UID is mailbox-scoped, so the cached row is stale after a move;
            // drop it and let the destination's next sync re-cache it.
            context.delete(message)
            try? context.save()
        } catch { failed(account, error) }
    }

    /// Best-effort trash mailbox for an account ("Deleted Messages" on iCloud,
    /// "[Gmail]/Trash" on Gmail, "Trash" elsewhere).
    func trashPath(for account: MailAccount) -> String {
        specialPath(for: account, matching: ["TRASH", "DELETED"], fallback: "Trash")
    }

    /// Best-effort sent mailbox ("Sent Messages" on iCloud, "[Gmail]/Sent Mail").
    func sentPath(for account: MailAccount) -> String {
        specialPath(for: account, matching: ["SENT"], fallback: "Sent")
    }

    private func specialPath(for account: MailAccount, matching needles: [String], fallback: String) -> String {
        let boxes = (try? context?.fetch(FetchDescriptor<Mailbox>())) ?? []
        let mine = boxes.filter { $0.accountID == account.id }
        if let match = mine.first(where: { box in
            let p = box.path.uppercased()
            return needles.contains { p.contains($0) }
        }) {
            return match.path
        }
        return fallback
    }

    // MARK: Send (§7: gated behind the compose confirm surface)

    func send(_ outgoing: OutgoingMessage, account: MailAccount) async throws {
        guard let password = MailKeychain.password(for: account.id) else { throw MailError.missingPassword }
        let config = MailServerConfig(host: account.smtpHost, port: account.smtpPort, username: account.emailAddress)
        let smtp = SMTPClient(config: config)
        let rendered = try await smtp.send(outgoing, password: password)

        // Save a copy to the Sent mailbox. Gmail already does this server-side
        // on SMTP send (an APPEND would duplicate); iCloud and most others
        // don't. Best-effort — a failed save never fails the send.
        if !account.smtpHost.lowercased().contains("gmail") {
            if let imap = await ensureConnected(account) {
                let sent = sentPath(for: account)
                do {
                    try await imap.append(path: sent, message: Data(rendered.utf8))
                    MailLog.log("[Mail] saved sent message to \(sent)")
                } catch {
                    MailLog.log("[Mail] couldn't save to Sent (\(sent)): \(error)")
                }
            }
        }
    }

    // MARK: - Cache upserts

    private func upsertMailboxes(_ infos: [MailboxInfo], accountID: UUID, in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Mailbox>())) ?? []
        var byPath = Dictionary(uniqueKeysWithValues: existing.filter { $0.accountID == accountID }.map { ($0.path, $0) })
        for (index, info) in infos.enumerated() {
            let box = byPath[info.path] ?? {
                let new = Mailbox(accountID: accountID, path: info.path, displayName: info.displayName)
                context.insert(new)
                byPath[info.path] = new
                return new
            }()
            box.displayName = info.displayName
            box.unreadCount = info.unreadCount
            box.totalCount = info.totalCount
            box.sortIndex = info.path.uppercased() == "INBOX" ? -1 : index
        }
    }

    /// Upserts summaries into the cache; returns the messages that were NEWLY
    /// inserted (rule processing runs only on true arrivals, never updates).
    @discardableResult
    private func upsertMessages(_ summaries: [MessageSummary], accountID: UUID, mailboxPath: String, in context: ModelContext) -> [MailMessage] {
        let existing = (try? context.fetch(FetchDescriptor<MailMessage>())) ?? []
        var byUID = Dictionary(
            existing
                .filter { $0.accountID == accountID && $0.mailboxPath == mailboxPath }
                .map { ($0.uid, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var inserted: [MailMessage] = []
        for summary in summaries {
            let message = byUID[summary.uid] ?? {
                let new = MailMessage(accountID: accountID, mailboxPath: mailboxPath, uid: summary.uid)
                context.insert(new)
                byUID[summary.uid] = new
                inserted.append(new)
                return new
            }()
            message.subject = summary.subject
            message.fromName = summary.fromName
            message.fromAddress = summary.fromAddress
            message.toRecipients = summary.toDisplay
            message.toAddressList = summary.toAddresses.joined(separator: ",")
            message.ccAddressList = summary.ccAddresses.joined(separator: ",")
            message.messageID = summary.messageID
            message.date = summary.date
            message.isSeen = summary.isSeen
            message.isFlagged = summary.isFlagged
        }
        return inserted
    }

    // MARK: Rules

    /// Run enabled rules over newly arrived INBOX messages. First matching
    /// terminal action (move/trash) wins; non-terminal actions all apply.
    private func applyRules(to newMessages: [MailMessage], account: MailAccount, in context: ModelContext) async {
        guard !newMessages.isEmpty else { return }
        let rules = ((try? context.fetch(FetchDescriptor<MailRule>())) ?? [])
            .filter(\.isEnabled)
            .sorted { $0.sortIndex < $1.sortIndex }
        guard !rules.isEmpty else { return }

        for message in newMessages {
            for rule in rules {
                guard rule.condition.matches(message) else { continue }
                let action = rule.action
                MailLog.log("[Rules] '\(rule.name)' matched uid \(message.uid): \(message.subject.prefix(40))")

                if action.markRead { await setSeen(message, account: account, seen: true) }
                if action.flag { await setFlagged(message, account: account, flagged: true) }
                if let tagID = action.addTagID, let header = message.messageID, !header.isEmpty {
                    let assignments = (try? context.fetch(FetchDescriptor<MailTagAssignment>())) ?? []
                    if !assignments.contains(where: { $0.tagID == tagID && $0.messageIDHeader == header }) {
                        context.insert(MailTagAssignment(tagID: tagID, messageIDHeader: header))
                    }
                }
                if action.moveToTrash {
                    await delete(message, account: account)
                    break // message left this mailbox; stop processing it
                }
                if !action.moveToMailboxPath.isEmpty {
                    await move(message, account: account, to: action.moveToMailboxPath)
                    break
                }
            }
        }
        try? context.save()
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case MailError.authenticationFailed: return "Login failed — check your email and app password."
        case MailError.connectionClosed: return "The server closed the connection."
        case MailError.notConnected: return "Not connected."
        case MailError.commandFailed(let m): return "Server error: \(m)"
        default: return error.localizedDescription
        }
    }
}
