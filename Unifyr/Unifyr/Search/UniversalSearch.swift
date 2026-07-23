//
//  UniversalSearch.swift
//  Unifyr
//
//  Spotlight-for-Unifyr: ⌘K opens a palette that searches every module —
//  notes (titles + block text), cached mail, calendar events, reminders,
//  contacts, message conversations, and files in the Drive locations. Picking
//  a result switches to the module and deep-links where the module supports
//  it (notification-based, posted after the module mounts).
//

import SwiftUI
import SwiftData

extension Notification.Name {
    static let unifyrOpenMailMessage = Notification.Name("unifyr.openMailMessage")
    static let unifyrOpenChat = Notification.Name("unifyr.openChat")
    static let unifyrOpenReminder = Notification.Name("unifyr.openReminder")
    static let unifyrOpenCalendarDate = Notification.Name("unifyr.openCalendarDate")
    /// The Messages local read ledger changed — the sidebar badge should
    /// recount now rather than waiting for the next poll tick.
    static let unifyrMessagesReadLocally = Notification.Name("unifyr.messagesReadLocally")
}

/// One hit in the palette. `notification` is the module deep-link (posted
/// shortly after switching so the destination view exists to receive it).
struct SearchHit: Identifiable {
    let id = UUID()
    let module: SidebarItem
    let icon: String
    let title: String
    let subtitle: String
    var notification: (name: Notification.Name, userInfo: [String: Any])?
    /// Files skip module navigation entirely.
    var revealURL: URL?
}

struct UniversalSearchView: View {
    /// Switch modules + deep-link; owned by ContentView.
    let onNavigate: (SearchHit) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var notesContext
    @Environment(\.mailContainer) private var mailContainer
    @Environment(\.brokers) private var brokers
    // Messages is Mac-only, so its search path is too (Drive is on both).
    #if os(macOS)
    @Environment(\.messagesDB) private var messagesDB
    #endif

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("Search Unifyr — notes, mail, events, reminders, contacts, messages, files…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit {
                        if let first = hits.first { pick(first) }
                    }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(Theme.Spacing.md)

            Divider().overlay(Theme.Palette.separator)

            if hits.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).count < 2
                     ? "Type to search across every module."
                     : (searching ? "Searching…" : "No results."))
                    .font(Theme.Font.cardBody)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedModules, id: \.self) { module in
                        Section(module.title) {
                            ForEach(hits.filter { $0.module == module }) { hit in
                                Button {
                                    pick(hit)
                                } label: {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        Image(systemName: hit.icon)
                                            .foregroundStyle(Theme.Palette.primary)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(hit.title)
                                                .font(Theme.Font.cardBody)
                                                .lineLimit(1)
                                            if !hit.subtitle.isEmpty {
                                                Text(hit.subtitle)
                                                    .font(Theme.Font.cardCaption)
                                                    .foregroundStyle(Theme.Palette.textSecondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 440)
        .background(Theme.Palette.background)
        .onAppear { fieldFocused = true }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200)) // debounce
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    private var groupedModules: [SidebarItem] {
        var seen: [SidebarItem] = []
        for hit in hits where !seen.contains(hit.module) {
            seen.append(hit.module)
        }
        return seen
    }

    private func pick(_ hit: SearchHit) {
        dismiss()
        onNavigate(hit)
    }

    // MARK: Search

    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            hits = []
            return
        }
        searching = true
        defer { searching = false }
        var results: [SearchHit] = []
        results += searchNotes(text)
        results += searchDatabaseRows(text)
        results += searchMail(text)
        results += await searchEvents(text)
        results += await searchReminders(text)
        results += await searchContacts(text)
        #if os(macOS)
        results += await searchChats(text)
        #endif
        results += await searchFiles(text)
        guard !Task.isCancelled else { return }
        hits = results
    }

    private func searchNotes(_ text: String) -> [SearchHit] {
        // Trashed notes are not results — a deleted note turning up in search
        // would undo the whole point of deleting it. The title match runs as
        // a store predicate; only when titles alone can't fill the result set
        // does the (crude but effective) block byte-scan run at all.
        let titleMatches = (try? notesContext.fetch(FetchDescriptor<Note>(
            predicate: #Predicate {
                !$0.isArchived && $0.deletedAt == nil && $0.title.localizedStandardContains(text)
            }
        ))) ?? []
        var matchedNoteIDs = Set(titleMatches.map(\.id))
        var matched = titleMatches
        if matchedNoteIDs.count < 12 {
            // contentJSON is Data, so it can't be matched in a #Predicate —
            // scan blocks of live notes, stopping once the set is full.
            let blocks = (try? notesContext.fetch(FetchDescriptor<Block>(
                predicate: #Predicate { $0.note?.deletedAt == nil }
            ))) ?? []
            for block in blocks where matchedNoteIDs.count < 12 {
                guard let note = block.note, !note.isArchived,
                      !matchedNoteIDs.contains(note.id) else { continue }
                if String(decoding: block.contentJSON, as: UTF8.self).localizedCaseInsensitiveContains(text) {
                    matchedNoteIDs.insert(note.id)
                    matched.append(note)
                }
            }
        }
        return matched
            .prefix(8)
            .map { note in
                SearchHit(
                    module: .notes,
                    icon: "note.text",
                    title: note.title.isEmpty ? "Untitled" : note.title,
                    subtitle: parentPageTitle(of: note) ?? "Top Level",
                    notification: (.unifyrOpenNote, ["id": note.id])
                )
            }
    }

    /// Database rows by cell content — "brake pads" should find the Car
    /// Maintenance row, not just pages. Cell JSON is a byte-scan like note
    /// blocks; hits deep-link straight to the row's page (.unifyrOpenDBRow).
    private func searchDatabaseRows(_ text: String) -> [SearchHit] {
        let values = (try? notesContext.fetch(FetchDescriptor<DBValue>())) ?? []
        let store = DatabaseStore(context: notesContext)
        var matchedRowIDs = Set<UUID>()
        var hits: [SearchHit] = []
        for value in values {
            guard hits.count < 6,
                  let rowID = value.rowID,
                  !matchedRowIDs.contains(rowID) else { continue }
            guard String(decoding: value.valueJSON, as: UTF8.self).localizedCaseInsensitiveContains(text) else { continue }
            guard let (row, database) = store.rowWithDatabase(id: rowID) else { continue }
            matchedRowIDs.insert(rowID)
            let title = store.rowTitle(
                row.id,
                titleProperty: store.titleProperty(among: store.fetchProperties(databaseNoteID: database.id))
            )
            hits.append(SearchHit(
                module: .notes,
                icon: "tablecells",
                title: title,
                subtitle: database.title.isEmpty ? "Untitled database" : database.title,
                notification: (.unifyrOpenDBRow, ["db": database.id, "row": row.id])
            ))
        }
        return hits
    }

    /// The containing page's title (Notion-style tree; folders left the UI).
    private func parentPageTitle(of note: Note) -> String? {
        guard let parentID = note.parentNoteID else { return nil }
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == parentID })
        descriptor.fetchLimit = 1
        guard let parent = ((try? notesContext.fetch(descriptor)) ?? []).first else { return nil }
        return parent.title.isEmpty ? "Untitled" : parent.title
    }

    private func searchMail(_ text: String) -> [SearchHit] {
        guard let mailContainer else { return [] }
        let context = ModelContext(mailContainer)
        // Predicate + sort + limit in the store: fetching the whole mail
        // cache on every (debounced) keystroke made the palette drag.
        var descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate {
                $0.subject.localizedStandardContains(text)
                    || $0.fromName.localizedStandardContains(text)
                    || $0.fromAddress.localizedStandardContains(text)
                    || $0.snippet.localizedStandardContains(text)
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 8
        let messages = (try? context.fetch(descriptor)) ?? []
        return messages
            .prefix(8)
            .map { message in
                SearchHit(
                    module: .mail,
                    icon: "envelope",
                    title: message.subject.isEmpty ? "(No Subject)" : message.subject,
                    subtitle: "\(message.fromName.isEmpty ? message.fromAddress : message.fromName) · \(message.date.formatted(date: .abbreviated, time: .omitted))",
                    notification: (.unifyrOpenMailMessage, ["id": message.id])
                )
            }
    }

    private func searchEvents(_ text: String) async -> [SearchHit] {
        let now = Date()
        let range = now.addingTimeInterval(-365 * 86_400)...now.addingTimeInterval(365 * 86_400)
        let events = (try? await brokers.eventKit.fetch(
            BrokerQuery(searchText: text, dateRange: range, limit: 8)
        )) ?? []
        return events.map { event in
            SearchHit(
                module: .calendar,
                icon: "calendar",
                title: event.title,
                subtitle: event.start.formatted(date: .abbreviated, time: .shortened),
                notification: (.unifyrOpenCalendarDate, ["date": event.start])
            )
        }
    }

    private func searchReminders(_ text: String) async -> [SearchHit] {
        let reminders = (try? await brokers.eventKit.fetchReminders(
            BrokerQuery(searchText: text, limit: 8, includeCompleted: true)
        )) ?? []
        return reminders.map { reminder in
            SearchHit(
                module: .reminders,
                icon: "checklist",
                title: reminder.title,
                subtitle: reminder.listTitle + (reminder.isCompleted ? " · completed" : ""),
                notification: (.unifyrOpenReminder, ["id": reminder.id])
            )
        }
    }

    private func searchContacts(_ text: String) async -> [SearchHit] {
        let contacts = (try? await brokers.contacts.fetch(BrokerQuery(searchText: text, limit: 6))) ?? []
        return contacts.map { contact in
            SearchHit(
                module: .contacts,
                icon: "person",
                title: contact.displayName,
                subtitle: contact.emailAddresses.first ?? contact.phoneNumbers.first ?? "",
                notification: nil
            )
        }
    }

    #if os(macOS)
    private func searchChats(_ text: String) async -> [SearchHit] {
        guard let messagesDB, await messagesDB.hasAccess() else { return [] }
        let chats = await messagesDB.chats()
        return chats
            .filter { chat in
                chat.displayName.localizedCaseInsensitiveContains(text)
                    || chat.participants.contains { $0.localizedCaseInsensitiveContains(text) }
                    || chat.lastPreview.localizedCaseInsensitiveContains(text)
            }
            .prefix(6)
            .map { chat in
                SearchHit(
                    module: .messages,
                    icon: "message",
                    title: chat.displayName.isEmpty ? chat.participants.joined(separator: ", ") : chat.displayName,
                    subtitle: chat.lastPreview,
                    notification: (.unifyrOpenChat, ["id": chat.id])
                )
            }
    }
    #endif

    /// Drive files. Both platforms — only the bookmark options differ (macOS
    /// security-scoped, iOS plain; the same split DriveLocations writes them
    /// with).
    private func searchFiles(_ text: String) async -> [SearchHit] {
        // Resolve the Drive bookmarks read-only for the scan.
        let bookmarks = (UserDefaults.standard.array(forKey: "drive.locationBookmarks") as? [Data]) ?? []
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        var roots: [URL] = []
        for data in bookmarks {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                roots.append(url)
            }
        }
        guard !roots.isEmpty else { return [] }
        let needle = text
        let found = await Task.detached(priority: .userInitiated) { () -> [(URL, String)] in
            // Synchronous helper: DirectoryEnumerator can't be iterated
            // directly from an async context.
            func scan(_ root: URL, into matches: inout [(URL, String)]) {
                var scanned = 0
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { return }
                while let entry = enumerator.nextObject() as? URL {
                    scanned += 1
                    if scanned > 4000 || matches.count >= 10 { return }
                    if entry.lastPathComponent.localizedCaseInsensitiveContains(needle) {
                        matches.append((entry, root.lastPathComponent))
                    }
                }
            }
            var matches: [(URL, String)] = []
            for root in roots {
                scan(root, into: &matches)
                if matches.count >= 10 { break }
            }
            return matches
        }.value
        return found.map { url, rootName in
            SearchHit(
                module: .drive,
                icon: "doc",
                title: url.lastPathComponent,
                subtitle: rootName + " · " + url.deletingLastPathComponent().lastPathComponent,
                notification: nil,
                revealURL: url
            )
        }
    }
}
