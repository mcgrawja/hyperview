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
        case "notes_tree": return try notesTree()
        case "notes_get": return try notesGet(id: try requireUUID(args, "id"))
        case "notes_create":
            return try notesCreate(
                title: try require(args, "title"),
                content: str(args, "content"),
                parentRef: str(args, "parent")
            )
        case "notes_append_blocks": return try notesAppend(id: try requireUUID(args, "id"), content: try require(args, "content"))
        case "notes_update_block": return try notesUpdateBlock(id: try requireUUID(args, "block_id"), content: try require(args, "content"))
        case "notes_toggle_todo": return try notesToggleTodo(id: try requireUUID(args, "block_id"))
        case "notes_archive": return try notesSetArchived(id: try requireUUID(args, "id"), archived: true)
        case "notes_restore": return try notesSetArchived(id: try requireUUID(args, "id"), archived: false)
        case "notes_delete": return try notesDelete(id: try requireUUID(args, "id"))
        case "notes_move":
            // "folder" accepted as a legacy alias (older cached tool schemas).
            return try notesMove(id: try requireUUID(args, "id"), parentRef: str(args, "parent") ?? str(args, "folder"))

        case "db_list": return try dbList()
        case "db_query":
            return try dbQuery(
                databaseRef: try require(args, "database"),
                viewRef: str(args, "view"),
                limit: (args["limit"] as? Double).map(Int.init) ?? 50
            )
        case "db_add_row":
            guard let values = args["values"] as? [String: Any] else { throw MCPError("values must be an object of column name → value") }
            return try dbAddRow(databaseRef: try require(args, "database"), values: values)
        case "db_update_row":
            guard let values = args["values"] as? [String: Any] else { throw MCPError("values must be an object of column name → value") }
            return try dbUpdateRow(rowID: try requireUUID(args, "row_id"), values: values)
        case "db_delete_row":
            return try dbDeleteRow(rowID: try requireUUID(args, "row_id"))

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
        let all = try allNotes()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let notes = all.filter { !$0.isArchived && !$0.isTrashed }
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
                    "kind": note.noteKind,
                    "modified": iso.string(from: note.modifiedAt),
                    "parent": note.parentNoteID.flatMap { byID[$0]?.title } ?? "",
                ]
            }
        return try json(["pages": Array(items)])
    }

    /// The page tree as an indented outline (cheap for Claude to read whole).
    private func notesTree() throws -> String {
        let all = try allNotes().filter { !$0.isArchived && !$0.isTrashed }
        let sorted = all.sorted { $0.sortKey < $1.sortKey }
        var lines: [String] = []
        func walk(_ parentID: UUID?, depth: Int) {
            guard depth < 16 else { return }
            for note in sorted where note.parentNoteID == parentID {
                let indent = String(repeating: "  ", count: depth)
                let kind = note.kind == .database ? " [database]" : ""
                let favorite = note.isFavorite ? " ★" : ""
                let title = note.title.isEmpty ? "Untitled" : note.title
                lines.append("\(indent)- \(title)\(kind)\(favorite) (\(note.id.uuidString))")
                walk(note.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        return try json(["tree": lines.joined(separator: "\n"), "count": all.count])
    }

    /// A page by uuid or (case-insensitive, then fuzzy) title.
    private func resolvePage(_ ref: String) throws -> Note {
        let live = try allNotes().filter { !$0.isTrashed && !$0.isArchived }
        if let id = UUID(uuidString: ref), let match = live.first(where: { $0.id == id }) { return match }
        if let match = live.first(where: { $0.title.localizedCaseInsensitiveCompare(ref) == .orderedSame }) { return match }
        if let match = live.first(where: { $0.title.localizedCaseInsensitiveContains(ref) }) { return match }
        throw MCPError("No page matching “\(ref)”. Use notes_tree to see the page list.")
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

    private func notesCreate(title: String, content: String?, parentRef: String?) throws -> String {
        let store = NotesStore(context: notesContext)
        let parent: Note?
        if let parentRef, !parentRef.isEmpty {
            let resolved = try resolvePage(parentRef)
            guard resolved.kind == .page else {
                throw MCPError("“\(resolved.title)” is a database — pages can only nest under pages. Use db_add_row to add to a database.")
            }
            parent = resolved
        } else {
            parent = nil
        }
        let note = store.createPage(title: title, parent: parent)
        if let content, !content.isEmpty {
            store.save(document(fromText: content), to: note)
        }
        try notesContext.save()
        return try json([
            "created": true,
            "id": note.id.uuidString,
            "parent": parent?.title ?? "Top Level",
        ])
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

    /// Soft-delete: moves the page (and its sub-pages) to Recently Deleted
    /// (recoverable).
    private func notesDelete(id: UUID) throws -> String {
        let all = try allNotes()
        guard let note = all.first(where: { $0.id == id }) else { throw MCPError("Note not found") }
        let title = note.title
        NotesStore(context: notesContext).delete(note, in: all)
        try notesContext.save()
        return try json(["deleted": true, "title": title, "note": "Moved to Recently Deleted; can be restored in Notes."])
    }

    private func notesMove(id: UUID, parentRef: String?) throws -> String {
        let all = try allNotes()
        guard let note = all.first(where: { $0.id == id }) else { throw MCPError("Note not found") }
        let store = NotesStore(context: notesContext)
        let parent: Note?
        if let parentRef, !parentRef.isEmpty {
            let resolved = try resolvePage(parentRef)
            guard resolved.kind == .page else {
                throw MCPError("“\(resolved.title)” is a database — pages can only nest under pages.")
            }
            parent = resolved
        } else {
            parent = nil
        }
        let before = note.parentNoteID
        store.move(note, toParent: parent, in: all)
        // The store refuses cycles silently; surface that as an error here.
        if let parent, note.parentNoteID == before, before != parent.id {
            throw MCPError("Can't move “\(note.title)” into its own sub-page.")
        }
        try notesContext.save()
        return try json(["moved": true, "title": note.title, "parent": parent?.title ?? "Top Level"])
    }

    // MARK: - Databases (Phase 6)

    private var dbStore: DatabaseStore { DatabaseStore(context: notesContext) }

    private func resolveDatabase(_ ref: String) throws -> Note {
        let databases = dbStore.databaseNotes()
        if let id = UUID(uuidString: ref), let match = databases.first(where: { $0.id == id }) { return match }
        if let match = databases.first(where: { $0.title.localizedCaseInsensitiveCompare(ref) == .orderedSame }) { return match }
        if let match = databases.first(where: { $0.title.localizedCaseInsensitiveContains(ref) }) { return match }
        let available = databases.map { $0.title.isEmpty ? "Untitled" : $0.title }.joined(separator: ", ")
        throw MCPError("No database matching “\(ref)”. Available: \(available.isEmpty ? "(none)" : available)")
    }

    private func dbList() throws -> String {
        let items = dbStore.databaseNotes().map { note -> [String: Any] in
            let properties = dbStore.fetchProperties(databaseNoteID: note.id).map { property -> [String: Any] in
                var out: [String: Any] = ["name": property.name, "kind": property.kind]
                if let options = dbStore.config(of: property).options, !options.isEmpty {
                    out["options"] = options.map(\.name)
                }
                if property.propertyKind == .relation,
                   let targetID = dbStore.config(of: property).relationTargetID,
                   let target = try? resolveDatabase(targetID.uuidString) {
                    out["relates_to"] = target.title
                }
                return out
            }
            return [
                "id": note.id.uuidString,
                "title": note.title.isEmpty ? "Untitled" : note.title,
                "columns": properties,
                "views": dbStore.views(of: note).map { ["id": $0.id.uuidString, "name": $0.name] },
                "row_count": dbStore.fetchRows(databaseNoteID: note.id).count,
            ]
        }
        return try json(["databases": items])
    }

    private func dbQuery(databaseRef: String, viewRef: String?, limit: Int) throws -> String {
        let note = try resolveDatabase(databaseRef)
        let properties = dbStore.fetchProperties(databaseNoteID: note.id)
        let rows = dbStore.fetchRows(databaseNoteID: note.id)

        var view: DBViewConfig?
        if let viewRef, !viewRef.isEmpty {
            let views = dbStore.views(of: note)
            view = views.first { $0.id.uuidString.caseInsensitiveCompare(viewRef) == .orderedSame }
                ?? views.first { $0.name.localizedCaseInsensitiveCompare(viewRef) == .orderedSame }
            guard view != nil else {
                throw MCPError("No view “\(viewRef)” on \(note.title). Views: \(views.map(\.name).joined(separator: ", "))")
            }
        }

        var values: [UUID: [UUID: DBCellValue]] = [:]
        for row in rows {
            for property in properties {
                let cell = dbStore.value(rowID: row.id, propertyID: property.id)
                if !cell.isEmpty { values[row.id, default: [:]][property.id] = cell }
            }
        }
        let visible = dbStore.apply(view, rows: rows, values: values, properties: properties)

        let items = visible.prefix(max(1, limit)).map { row -> [String: Any] in
            var cells: [String: Any] = [:]
            for property in properties {
                let text = dbStore.displayText(values[row.id]?[property.id] ?? DBCellValue(), property: property)
                if !text.isEmpty { cells[property.name] = text }
            }
            return ["row_id": row.id.uuidString, "values": cells]
        }
        return try json([
            "database": note.title,
            "view": view?.name ?? "",
            "total": visible.count,
            "rows": Array(items),
        ])
    }

    private func applyValues(_ values: [String: Any], to row: DBRow, in note: Note) throws -> [String] {
        let properties = dbStore.fetchProperties(databaseNoteID: note.id)
        var applied: [String] = []
        for (name, raw) in values {
            guard let property = properties.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                let available = properties.map(\.name).joined(separator: ", ")
                throw MCPError("No column “\(name)” in \(note.title). Columns: \(available)")
            }
            let cell = dbStore.toolCellValue(raw, property: property)
            dbStore.setValue(cell, rowID: row.id, propertyID: property.id, in: note)
            applied.append(property.name)
        }
        return applied
    }

    private func dbAddRow(databaseRef: String, values: [String: Any]) throws -> String {
        let note = try resolveDatabase(databaseRef)
        let row = dbStore.addRow(to: note)
        let applied = try applyValues(values, to: row, in: note)
        try notesContext.save()
        return try json(["added": true, "row_id": row.id.uuidString, "database": note.title, "set": applied])
    }

    private func dbUpdateRow(rowID: UUID, values: [String: Any]) throws -> String {
        guard let (row, note) = dbStore.rowWithDatabase(id: rowID) else {
            throw MCPError("Row not found — ids come from db_query.")
        }
        let applied = try applyValues(values, to: row, in: note)
        try notesContext.save()
        return try json(["updated": true, "database": note.title, "set": applied])
    }

    private func dbDeleteRow(rowID: UUID) throws -> String {
        guard let (row, note) = dbStore.rowWithDatabase(id: rowID) else {
            throw MCPError("Row not found — ids come from db_query.")
        }
        let title = dbStore.rowTitle(row.id, titleProperty: dbStore.titleProperty(
            among: dbStore.fetchProperties(databaseNoteID: note.id)
        ))
        dbStore.deleteRow(row, in: note)
        try notesContext.save()
        return try json(["deleted": true, "row": title, "database": note.title])
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
