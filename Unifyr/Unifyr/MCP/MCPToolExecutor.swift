//
//  MCPToolExecutor.swift
//  Unifyr
//
//  Executes §7 tools against the live brokers and stores. Transport-agnostic:
//  the HTTP shim (→ Node bridge → Claude Desktop) calls this today; a future
//  in-app API client (Phase 5) calls the same executor. Runs on the main actor
//  because NotesStore/MailService and the SwiftData main contexts live there.
//

import Foundation
import SwiftData

@MainActor
final class MCPToolExecutor {
    private let brokers: Brokers
    private let notesContext: ModelContext
    private let mailContext: ModelContext
    private let mailService: MailService
    private let onAudit: (String, String, Bool) -> Void

    private let iso = ISO8601DateFormatter()

    init(
        brokers: Brokers,
        notesContainer: ModelContainer,
        mailContainer: ModelContainer,
        mailService: MailService,
        onAudit: @escaping (String, String, Bool) -> Void
    ) {
        self.brokers = brokers
        self.notesContext = notesContainer.mainContext
        self.mailContext = mailContainer.mainContext
        self.mailService = mailService
        self.onAudit = onAudit
        if mailService.context == nil { mailService.context = mailContext }
    }

    /// Transport entry point: parse a /call body on the main actor (raw Data
    /// crosses the actor boundary; `[String: Any]` could not).
    func execute(callBody: Data) async -> (ok: Bool, content: String) {
        guard let payload = try? JSONSerialization.jsonObject(with: callBody) as? [String: Any],
              let name = payload["name"] as? String else {
            return (false, "Error: request body must be {\"name\":..., \"arguments\":{...}}")
        }
        let arguments = (payload["arguments"] as? [String: Any]) ?? [:]
        return await execute(name: name, arguments: arguments)
    }

    /// Run a tool; returns a JSON string (or throws a readable error).
    func execute(name: String, arguments: [String: Any]) async -> (ok: Bool, content: String) {
        do {
            let content = try await dispatch(name: name, arguments: arguments)
            onAudit(name, summarize(arguments), true)
            return (true, content)
        } catch {
            onAudit(name, "\(summarize(arguments)) — \(error.localizedDescription)", false)
            return (false, "Error: \(readable(error))")
        }
    }

    // MARK: - Dispatch

    private func dispatch(name: String, arguments args: [String: Any]) async throws -> String {
        switch name {
        case "notes_search": return try notesSearch(query: str(args, "query") ?? "")
        case "notes_get": return try notesGet(id: try requireUUID(args, "id"))
        case "notes_create": return try notesCreate(title: try require(args, "title"), content: str(args, "content"))
        case "notes_append_blocks": return try notesAppend(id: try requireUUID(args, "id"), content: try require(args, "content"))
        case "notes_update_block": return try notesUpdateBlock(id: try requireUUID(args, "block_id"), content: try require(args, "content"))
        case "notes_toggle_todo": return try notesToggleTodo(id: try requireUUID(args, "block_id"))
        case "notes_archive": return try notesSetArchived(id: try requireUUID(args, "id"), archived: true)
        case "notes_restore": return try notesSetArchived(id: try requireUUID(args, "id"), archived: false)
        case "notes_delete": return try notesDelete(id: try requireUUID(args, "id"))
        case "notes_move": return try notesMove(id: try requireUUID(args, "id"), folderName: str(args, "folder"))

        case "calendar_today":
            return try encode(try await brokers.eventKit.fetchTodayEvents())
        case "calendar_query":
            let range = try isoDate(try require(args, "start"))...(try isoDate(try require(args, "end")))
            return try encode(try await brokers.eventKit.fetch(BrokerQuery(searchText: str(args, "search"), dateRange: range)))
        case "calendar_create_event":
            let event = try await brokers.eventKit.createEvent(
                title: try require(args, "title"),
                start: try isoDate(try require(args, "start")),
                end: try isoDate(try require(args, "end")),
                isAllDay: (args["all_day"] as? Bool) ?? false,
                notes: str(args, "notes")
            )
            return try encode(event)
        case "calendar_update_event":
            let updated = try await brokers.eventKit.updateEvent(
                id: try require(args, "id"),
                title: str(args, "title"),
                start: str(args, "start").flatMap { try? isoDate($0) },
                end: str(args, "end").flatMap { try? isoDate($0) },
                location: str(args, "location"),
                notes: str(args, "notes")
            )
            return try encode(updated)
        case "calendar_delete_event":
            try await brokers.eventKit.deleteEvent(id: try require(args, "id"))
            return #"{"deleted":true}"#

        case "reminders_due":
            let days = (args["days"] as? Double).map(Int.init) ?? 7
            return try encode(try await brokers.eventKit.fetchDueReminders(within: TimeInterval(days) * 86_400))
        case "reminders_create":
            let reminder = try await brokers.eventKit.createReminder(
                title: try require(args, "title"),
                dueDate: str(args, "due").flatMap { try? isoDate($0) },
                notes: str(args, "notes")
            )
            return try encode(reminder)
        case "reminders_complete":
            try await brokers.eventKit.completeReminder(id: try require(args, "id"))
            return #"{"completed":true}"#
        case "reminders_uncomplete":
            try await brokers.eventKit.uncompleteReminder(id: try require(args, "id"))
            return #"{"completed":false,"restored":true}"#
        case "reminders_update":
            let updated = try await brokers.eventKit.updateReminder(
                id: try require(args, "id"),
                title: str(args, "title"),
                dueDate: str(args, "due").flatMap { try? isoDate($0) },
                notes: str(args, "notes")
            )
            return try encode(updated)
        case "reminders_delete":
            try await brokers.eventKit.deleteReminder(id: try require(args, "id"))
            return #"{"deleted":true}"#

        case "mail_unread": return try mailUnread(limit: (args["limit"] as? Double).map(Int.init) ?? 25)
        case "mail_sync": return try await mailSync()
        case "mail_search": return try await mailSearch(query: try require(args, "query"), account: str(args, "account"))
        case "mail_get_message":
            return try await mailGetMessage(
                account: try require(args, "account"),
                mailbox: try require(args, "mailbox"),
                uid: Int((args["uid"] as? Double) ?? -1)
            )
        case "mail_draft": return try mailDraft(args)
        case "mail_send": return try await mailSend(args)
        case "mail_delete":
            return try await mailDelete(
                account: try require(args, "account"),
                mailbox: try require(args, "mailbox"),
                uid: Int((args["uid"] as? Double) ?? -1)
            )

        #if os(macOS)
        case "messages_send":
            try MessagesSender.send(
                try require(args, "body"),
                toHandle: try require(args, "to"),
                service: str(args, "service") ?? "iMessage"
            )
            return try json(["sent": true, "to": try require(args, "to")])
        #endif

        case "contacts_search":
            return try encode(try await brokers.contacts.fetch(BrokerQuery(searchText: try require(args, "query"), limit: 25)))
        case "contacts_get":
            return try encode(try await brokers.contacts.get(id: try require(args, "id")))
        case "contacts_update":
            let split: (String?) -> [String]? = { raw in
                raw.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            }
            let updated = try await brokers.contacts.updateContact(
                id: try require(args, "id"),
                givenName: str(args, "given_name"),
                familyName: str(args, "family_name"),
                organization: str(args, "organization"),
                emails: split(str(args, "emails")),
                phones: split(str(args, "phones"))
            )
            return try encode(updated)

        case "photos_recent_metadata":
            let days = (args["days"] as? Double).map(Int.init) ?? 7
            return try encode(try await brokers.photos.fetchRecent(days: days, limit: 100))

        case "dashboard_briefing": return try await briefing()

        case "drive_locations": return try driveListLocations()
        case "drive_list": return try await driveList(location: try require(args, "location"), path: str(args, "path") ?? "")
        case "drive_read": return try await driveRead(location: try require(args, "location"), path: try require(args, "path"))
        case "drive_write":
            return try await driveWrite(
                location: try require(args, "location"),
                path: try require(args, "path"),
                content: try require(args, "content")
            )

        default:
            throw MCPError("Unknown tool: \(name)")
        }
    }

    // MARK: - Drive

    /// A place Claude can browse: a local/iCloud folder the user added, or a
    /// WebDAV server. Resolved fresh per call (bookmarks + UserDefaults), so the
    /// executor holds no Drive state and leaks no iCloud-KVS observer.
    private enum DriveLocation {
        case local(root: URL)
        case webdav(DriveServer)
    }

    private func driveLocationNames() -> [(name: String, location: DriveLocation)] {
        var out: [(String, DriveLocation)] = []
        let bookmarks = (UserDefaults.standard.array(forKey: "drive.locationBookmarks") as? [Data]) ?? []
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        for data in bookmarks {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                out.append((url.lastPathComponent, .local(root: url)))
            }
        }
        if let data = UserDefaults.standard.data(forKey: "drive.servers"),
           let servers = try? JSONDecoder().decode([DriveServer].self, from: data) {
            for server in servers { out.append((server.title, .webdav(server))) }
        }
        return out
    }

    private func resolveDriveLocation(_ name: String) throws -> DriveLocation {
        let all = driveLocationNames()
        guard let match = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let names = all.map(\.name).joined(separator: ", ")
            throw MCPError("No Drive location named “\(name)”. Available: \(names.isEmpty ? "(none — add one in Drive first)" : names)")
        }
        return match.location
    }

    private func webDAVClient(for server: DriveServer) -> WebDAVClient? {
        guard let url = server.url else { return nil }
        // Same Keychain coordinates DriveServers uses.
        let password = SyncedKeychain.read(service: "com.mcgraw.Hyperview.webdav", account: server.credentialAccount) ?? ""
        return WebDAVClient(baseURL: url, username: server.username, password: password)
    }

    private func webDAVURL(_ server: DriveServer, path: String) -> URL? {
        guard var url = server.url else { return nil }
        for component in path.split(separator: "/") where !component.isEmpty {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func driveListLocations() throws -> String {
        let items = driveLocationNames().map { entry -> [String: Any] in
            switch entry.location {
            case .local: return ["name": entry.name, "kind": "folder"]
            case .webdav: return ["name": entry.name, "kind": "server"]
            }
        }
        return try json(["locations": items])
    }

    private func driveList(location name: String, path: String) async throws -> String {
        switch try resolveDriveLocation(name) {
        case .local(let root):
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let dir = path.isEmpty ? root : root.appendingPathComponent(path)
            let urls = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            let items = urls.map { url -> [String: Any] in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                var item: [String: Any] = ["name": url.lastPathComponent, "kind": (values?.isDirectory ?? false) ? "folder" : "file"]
                if let size = values?.fileSize { item["size"] = size }
                return item
            }
            return try json(["location": name, "path": path, "items": items])
        case .webdav(let server):
            guard let client = webDAVClient(for: server) else { throw MCPError("That server isn't configured correctly.") }
            let entries = try await client.list(path.isEmpty ? nil : webDAVURL(server, path: path))
            let items = entries.map { entry -> [String: Any] in
                var item: [String: Any] = ["name": entry.name, "kind": entry.isDirectory ? "folder" : "file"]
                if let size = entry.size { item["size"] = size }
                return item
            }
            return try json(["location": name, "path": path, "items": items])
        }
    }

    private func driveRead(location name: String, path: String) async throws -> String {
        let data: Data
        switch try resolveDriveLocation(name) {
        case .local(let root):
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            data = try Data(contentsOf: root.appendingPathComponent(path))
        case .webdav(let server):
            guard let client = webDAVClient(for: server), let url = webDAVURL(server, path: path) else {
                throw MCPError("That server isn't configured correctly.")
            }
            let local = try await client.download(url)
            data = try Data(contentsOf: local)
            try? FileManager.default.removeItem(at: local)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPError("That file isn't UTF-8 text (\(data.count) bytes) — Drive read only handles text files.")
        }
        return try json(["path": path, "content": String(text.prefix(40_000)), "truncated": text.count > 40_000])
    }

    private func driveWrite(location name: String, path: String, content: String) async throws -> String {
        let data = Data(content.utf8)
        switch try resolveDriveLocation(name) {
        case .local(let root):
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        case .webdav(let server):
            guard let client = webDAVClient(for: server) else { throw MCPError("That server isn't configured correctly.") }
            let folderPath = (path as NSString).deletingLastPathComponent
            let filename = (path as NSString).lastPathComponent
            guard !filename.isEmpty, let folder = webDAVURL(server, path: folderPath) else {
                throw MCPError("Invalid path “\(path)”.")
            }
            try await client.upload(data, toFolder: folder, as: filename)
        }
        return try json(["written": true, "location": name, "path": path, "bytes": data.count])
    }

    // MARK: - Notes

    private func allNotes() throws -> [Note] {
        try notesContext.fetch(FetchDescriptor<Note>())
    }

    private func notesSearch(query: String) throws -> String {
        let notes = try allNotes().filter { !$0.isArchived }
        let matches = query.isEmpty
            ? notes
            : notes.filter { note in
                note.title.localizedCaseInsensitiveContains(query)
                    || (note.blocks ?? []).contains {
                        String(decoding: $0.contentJSON, as: UTF8.self).localizedCaseInsensitiveContains(query)
                    }
            }
        let items = matches
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(25)
            .map { note -> [String: Any] in
                [
                    "id": note.id.uuidString,
                    "title": note.title.isEmpty ? "Untitled" : note.title,
                    "modified": iso.string(from: note.modifiedAt),
                    "folder": note.folder?.name ?? "",
                ]
            }
        return try json(["notes": Array(items)])
    }

    private func notesGet(id: UUID) throws -> String {
        guard let note = try allNotes().first(where: { $0.id == id }) else { throw MCPError("Note not found") }
        let blocks = (note.blocks ?? []).sorted { $0.sortKey < $1.sortKey }
        let lines = blocks.map { block -> [String: Any] in
            [
                "block_id": block.id.uuidString,
                "kind": block.kind,
                "checked": block.isChecked,
                "text": plainText(of: block),
            ]
        }
        return try json([
            "id": note.id.uuidString,
            "title": note.title,
            "blocks": lines,
        ])
    }

    private func notesCreate(title: String, content: String?) throws -> String {
        let store = NotesStore(context: notesContext)
        let note = store.createNote(title: title)
        if let content, !content.isEmpty {
            store.save(document(fromText: content), to: note)
        }
        try notesContext.save()
        return try json(["created": true, "id": note.id.uuidString])
    }

    private func notesAppend(id: UUID, content: String) throws -> String {
        guard let note = try allNotes().first(where: { $0.id == id }) else { throw MCPError("Note not found") }
        let store = NotesStore(context: notesContext)
        var doc = store.loadDocument(note)
        var children = doc.content ?? []
        children.append(contentsOf: document(fromText: content).content ?? [])
        doc.content = children
        store.save(doc, to: note)
        try notesContext.save()
        return #"{"appended":true}"#
    }

    private func notesUpdateBlock(id: UUID, content: String) throws -> String {
        guard let block = try notesContext.fetch(FetchDescriptor<Block>()).first(where: { $0.id == id }) else {
            throw MCPError("Block not found")
        }
        var current = BlockSerializer.content(of: block)
        current.content = content.isEmpty ? [] : [.text(content)]
        BlockSerializer.apply(current, to: block)
        block.note?.modifiedAt = Date()
        try notesContext.save()
        return #"{"updated":true}"#
    }

    private func notesSetArchived(id: UUID, archived: Bool) throws -> String {
        guard let note = try allNotes().first(where: { $0.id == id }) else { throw MCPError("Note not found") }
        NotesStore(context: notesContext).archive(note, archived)
        try notesContext.save()
        return try json(["archived": archived, "title": note.title])
    }

    /// Soft-delete: moves the note to Recently Deleted (recoverable).
    private func notesDelete(id: UUID) throws -> String {
        guard let note = try allNotes().first(where: { $0.id == id }) else { throw MCPError("Note not found") }
        let title = note.title
        NotesStore(context: notesContext).delete(note)
        try notesContext.save()
        return try json(["deleted": true, "title": title, "note": "Moved to Recently Deleted; can be restored in Notes."])
    }

    private func notesMove(id: UUID, folderName: String?) throws -> String {
        guard let note = try allNotes().first(where: { $0.id == id }) else { throw MCPError("Note not found") }
        if let folderName, !folderName.isEmpty {
            let folders = try notesContext.fetch(FetchDescriptor<Folder>())
            guard let folder = folders.first(where: { $0.name.caseInsensitiveCompare(folderName) == .orderedSame }) else {
                let available = folders.map(\.name).sorted().joined(separator: ", ")
                throw MCPError("No folder named “\(folderName)”. Available folders: \(available.isEmpty ? "(none)" : available)")
            }
            note.folder = folder
        } else {
            note.folder = nil // top level / All Notes
        }
        note.modifiedAt = Date()
        try notesContext.save()
        return try json(["moved": true, "title": note.title, "folder": note.folder?.name ?? "All Notes"])
    }

    private func notesToggleTodo(id: UUID) throws -> String {
        guard let block = try notesContext.fetch(FetchDescriptor<Block>()).first(where: { $0.id == id }) else {
            throw MCPError("Block not found")
        }
        NotesStore(context: notesContext).toggleTodo(block)
        try notesContext.save()
        return try json(["checked": block.isChecked])
    }

    /// Lines → paragraphs; "- " lines → bullets.
    private func document(fromText text: String) -> PMNode {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line -> BlockContent in
                if line.hasPrefix("- ") {
                    return BlockContent(kind: .bullet, content: [.text(String(line.dropFirst(2)))])
                }
                return BlockContent(kind: .paragraph, content: line.isEmpty ? [] : [.text(line)])
            }
        return BlockSerializer.document(from: blocks)
    }

    private func plainText(of block: Block) -> String {
        let content = BlockSerializer.content(of: block)
        return content.content.compactMap(\.text).joined()
    }

    // MARK: - Mail

    private func allAccounts() throws -> [MailAccount] {
        try mailContext.fetch(FetchDescriptor<MailAccount>())
    }

    private func mailUnread(limit: Int) throws -> String {
        let accounts = try allAccounts()
        let emailByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.emailAddress) })
        let messages = try mailContext.fetch(FetchDescriptor<MailMessage>())
            .filter { !$0.isSeen && $0.mailboxPath.uppercased() == "INBOX" }
            .sorted { $0.date > $1.date }
            .prefix(limit)
        return try json(["unread": messages.map { summary($0, accountEmail: emailByID[$0.accountID] ?? "?") }])
    }

    private func mailSync() async throws -> String {
        var counts: [String: Any] = [:]
        for account in try allAccounts() {
            await mailService.syncMessages(account, mailboxPath: "INBOX")
            let unread = try mailContext.fetch(FetchDescriptor<MailMessage>())
                .filter { $0.accountID == account.id && !$0.isSeen && $0.mailboxPath.uppercased() == "INBOX" }
                .count
            counts[account.emailAddress] = unread
        }
        return try json(["synced": true, "unread_counts": counts])
    }

    private func mailSearch(query: String, account: String?) async throws -> String {
        let targets = try allAccounts().filter { account == nil || $0.emailAddress.caseInsensitiveCompare(account!) == .orderedSame }
        guard !targets.isEmpty else { throw MCPError("No matching account") }
        for target in targets {
            await mailService.search(target, mailboxPath: "INBOX", query: query)
        }
        let emailByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.emailAddress) })
        let ids = Set(targets.map(\.id))
        let matches = try mailContext.fetch(FetchDescriptor<MailMessage>())
            .filter { message in
                ids.contains(message.accountID) && (
                    message.subject.localizedCaseInsensitiveContains(query)
                        || message.fromName.localizedCaseInsensitiveContains(query)
                        || message.fromAddress.localizedCaseInsensitiveContains(query)
                )
            }
            .sorted { $0.date > $1.date }
            .prefix(25)
        return try json(["results": matches.map { summary($0, accountEmail: emailByID[$0.accountID] ?? "?") }])
    }

    private func mailGetMessage(account: String, mailbox: String, uid: Int) async throws -> String {
        guard let target = try allAccounts().first(where: { $0.emailAddress.caseInsensitiveCompare(account) == .orderedSame }) else {
            throw MCPError("Unknown account \(account)")
        }
        guard let message = try mailContext.fetch(FetchDescriptor<MailMessage>())
            .first(where: { $0.accountID == target.id && $0.mailboxPath == mailbox && $0.uid == uid }) else {
            throw MCPError("Message not found in cache — run mail_sync or mail_search first")
        }
        if !message.hasFetchedBody {
            await mailService.loadBody(message, account: target)
        }
        let body = message.bodyText ?? (message.bodyHTML.map(MailText.strip)) ?? "(no content)"
        return try json([
            "from": "\(message.fromName) <\(message.fromAddress)>",
            "subject": message.subject,
            "date": iso.string(from: message.date),
            "body": String(body.prefix(20_000)),
        ])
    }

    /// DRAFT ONLY (§7 safety) — returns the draft; sending happens in-app.
    private func mailDraft(_ args: [String: Any]) throws -> String {
        let account = try str(args, "account") ?? (allAccounts().first?.emailAddress ?? "")
        return try json([
            "draft": [
                "from": account,
                "to": try require(args, "to"),
                "subject": try require(args, "subject"),
                "body": try require(args, "body"),
            ],
            "note": "Draft only — open Unifyr → Mail → Compose to review and send.",
        ])
    }

    /// Actually send mail via SMTP. Gated behind an in-chat confirmation by the
    /// caller (ClaudeChatController); the MCP server path never reaches this
    /// tool because it isn't registered there without a confirmation surface.
    private func mailSend(_ args: [String: Any]) async throws -> String {
        let accounts = try allAccounts()
        guard !accounts.isEmpty else { throw MCPError("No mail accounts are configured in Unifyr.") }
        let account = str(args, "account")
            .flatMap { email in accounts.first { $0.emailAddress.caseInsensitiveCompare(email) == .orderedSame } }
            ?? accounts[0]
        let recipients = try require(args, "to")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !recipients.isEmpty else { throw MCPError("No recipients.") }
        let cc = (str(args, "cc") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let outgoing = OutgoingMessage(
            fromAddress: account.emailAddress,
            fromName: account.displayName,
            to: recipients,
            cc: cc,
            subject: try require(args, "subject"),
            body: try require(args, "body")
        )
        try await mailService.send(outgoing, account: account)
        return try json(["sent": true, "from": account.emailAddress, "to": recipients])
    }

    /// Delete = move to the account's server Trash (MailService.delete), then the
    /// cached row is dropped. Gated behind the in-chat confirmation by the caller.
    private func mailDelete(account: String, mailbox: String, uid: Int) async throws -> String {
        guard let target = try allAccounts().first(where: { $0.emailAddress.caseInsensitiveCompare(account) == .orderedSame }) else {
            throw MCPError("Unknown account \(account)")
        }
        guard let message = try mailContext.fetch(FetchDescriptor<MailMessage>())
            .first(where: { $0.accountID == target.id && $0.mailboxPath == mailbox && $0.uid == uid }) else {
            throw MCPError("Message not found in cache — run mail_sync or mail_search first")
        }
        let subject = message.subject
        await mailService.delete(message, account: target)
        return try json([
            "deleted": true,
            "subject": subject.isEmpty ? "(no subject)" : subject,
            "note": "Moved to the account's Trash mailbox on the server.",
        ])
    }

    private func summary(_ message: MailMessage, accountEmail: String) -> [String: Any] {
        [
            "account": accountEmail,
            "mailbox": message.mailboxPath,
            "uid": message.uid,
            // Local cache UUID — the in-app deep-link key (briefing → Mail).
            "id": message.id.uuidString,
            "from": message.fromName.isEmpty ? message.fromAddress : message.fromName,
            "from_address": message.fromAddress,
            "subject": message.subject,
            "date": iso.string(from: message.date),
            "unread": !message.isSeen,
        ]
    }

    // MARK: - Briefing

    private func briefing() async throws -> String {
        var out: [String: Any] = [:]
        if let events = try? await brokers.eventKit.fetchTodayEvents() {
            out["today_events"] = events.map { event -> [String: Any] in
                var item: [String: Any] = [
                    "title": event.title,
                    "start": iso.string(from: event.start),
                    "end": iso.string(from: event.end),
                    "all_day": event.isAllDay,
                    "calendar": event.calendarTitle,
                ]
                if let location = event.location, !location.isEmpty { item["location"] = location }
                if let notes = event.notes, !notes.isEmpty { item["notes"] = String(notes.prefix(300)) }
                return item
            }
        }
        if let reminders = try? await brokers.eventKit.fetchDueReminders() {
            out["due_reminders"] = reminders.prefix(15).map { reminder -> [String: Any] in
                var item: [String: Any] = ["title": reminder.title, "id": reminder.id]
                if let due = reminder.dueDate { item["due"] = iso.string(from: due) }
                return item
            }
        }
        if let accounts = try? allAccounts() {
            let messages = (try? mailContext.fetch(FetchDescriptor<MailMessage>())) ?? []
            out["unread_mail"] = accounts.map { account -> [String: Any] in
                let unread = messages.filter { $0.accountID == account.id && !$0.isSeen && $0.mailboxPath.uppercased() == "INBOX" }
                return ["account": account.emailAddress, "unread": unread.count,
                        "latest": unread.sorted { $0.date > $1.date }.first?.subject ?? ""]
            }
        }
        return try json(out)
    }

    // MARK: - Helpers

    private func str(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func require(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = str(args, key) else { throw MCPError("Missing required argument '\(key)'") }
        return value
    }

    private func requireUUID(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let uuid = UUID(uuidString: try require(args, key)) else { throw MCPError("'\(key)' is not a valid UUID") }
        return uuid
    }

    private func isoDate(_ raw: String) throws -> Date {
        if let date = iso.date(from: raw) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fallback.date(from: raw) { return date }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let date = dateOnly.date(from: raw) { return date }
        throw MCPError("Invalid ISO 8601 date: \(raw)")
    }

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func summarize(_ args: [String: Any]) -> String {
        args.isEmpty ? "" : args.map { "\($0)=\(String(describing: $1).prefix(40))" }.sorted().joined(separator: " ")
    }

    private func readable(_ error: Error) -> String {
        if let mcp = error as? MCPError { return mcp.message }
        if let broker = error as? BrokerError {
            switch broker {
            case .accessDenied: return "Unifyr doesn't have permission for that module — open the app and connect it first."
            case .accessRestricted: return "Access restricted by system policy."
            case .notFound: return "Not found."
            case .invalidInput(let detail): return "Invalid input: \(detail)"
            case .underlying(let detail): return detail
            }
        }
        return error.localizedDescription
    }
}

nonisolated struct MCPError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
