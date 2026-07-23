//
//  PinnedCards.swift
//  Unifyr
//
//  "Pin to Dashboard": notes and reminders pinned via their context menus
//  surface here as dedicated cards (each card renders only while something is
//  pinned). Pins are device-local UserDefaults state; clicking a row jumps to
//  the item in its module (via ContentView's reveal handlers, which switch
//  modules before posting the open notification).
//

import SwiftUI
import SwiftData

extension Notification.Name {
    static let unifyrPinsChanged = Notification.Name("unifyr.pinsChanged")
    /// userInfo: ["id": UUID] — switch to Notes, then open the note.
    static let unifyrRevealNote = Notification.Name("unifyr.revealNote")
    /// userInfo: ["id": String] — switch to Reminders, then select it.
    static let unifyrRevealReminder = Notification.Name("unifyr.revealReminder")
}

@MainActor
enum PinStore {
    private static let notesKey = "dashboard.pinnedNotes"
    private static let remindersKey = "dashboard.pinnedReminders"
    private static let dbViewsKey = "dashboard.pinnedDBViews"

    // MARK: Database views ("db|view" or "db|" for the All view — round 5)

    static func pinnedDBViews() -> [(databaseID: UUID, viewID: UUID?)] {
        let raw = UserDefaults.standard.stringArray(forKey: dbViewsKey) ?? []
        return raw.compactMap { entry in
            let parts = entry.split(separator: "|", omittingEmptySubsequences: false)
            guard let databaseID = UUID(uuidString: String(parts.first ?? "")) else { return nil }
            let viewID = parts.count > 1 ? UUID(uuidString: String(parts[1])) : nil
            return (databaseID, viewID)
        }
    }

    static func isPinned(databaseView databaseID: UUID, viewID: UUID?) -> Bool {
        pinnedDBViews().contains { $0.databaseID == databaseID && $0.viewID == viewID }
    }

    static func toggle(databaseView databaseID: UUID, viewID: UUID?) {
        let key = "\(databaseID.uuidString)|\(viewID?.uuidString ?? "")"
        var raw = UserDefaults.standard.stringArray(forKey: dbViewsKey) ?? []
        if let index = raw.firstIndex(of: key) {
            raw.remove(at: index)
        } else {
            raw.append(key)
        }
        UserDefaults.standard.set(raw, forKey: dbViewsKey)
    }

    static var pinnedNoteIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: notesKey) ?? [])
    }

    static var pinnedReminderIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: remindersKey) ?? [])
    }

    static func isPinned(note id: UUID) -> Bool {
        pinnedNoteIDs.contains(id.uuidString)
    }

    static func isPinned(reminder id: String) -> Bool {
        pinnedReminderIDs.contains(id)
    }

    static func toggle(note id: UUID) {
        var ids = pinnedNoteIDs
        if !ids.insert(id.uuidString).inserted { ids.remove(id.uuidString) }
        UserDefaults.standard.set(Array(ids), forKey: notesKey)
        NotificationCenter.default.post(name: .unifyrPinsChanged, object: nil)
    }

    static func toggle(reminder id: String) {
        var ids = pinnedReminderIDs
        if !ids.insert(id).inserted { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: remindersKey)
        NotificationCenter.default.post(name: .unifyrPinsChanged, object: nil)
    }
}

// MARK: - Pinned Notes card

struct PinnedNotesCard: View {
    @Query(sort: \Note.sortKey) private var notes: [Note]
    @State private var pinnedIDs = PinStore.pinnedNoteIDs

    private var pinnedNotes: [Note] {
        notes.filter { !$0.isArchived && pinnedIDs.contains($0.id.uuidString) }
    }

    var body: some View {
        let visible = pinnedNotes
        if !visible.isEmpty {
            DashboardCard(title: "Pinned Notes", systemImage: "pin") {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(visible) { note in
                        Button {
                            NotificationCenter.default.post(
                                name: .unifyrRevealNote, object: nil, userInfo: ["id": note.id]
                            )
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Text(note.emoji ?? "📝")
                                Text(note.title.isEmpty ? "Untitled" : note.title)
                                    .font(Theme.Font.cardBody)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Unpin from Dashboard") { PinStore.toggle(note: note.id) }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .unifyrPinsChanged)) { _ in
                pinnedIDs = PinStore.pinnedNoteIDs
            }
        }
    }
}

// MARK: - Pinned Reminders card

/// One card per pinned database view: the view's first rows, live (round 5).
/// Tapping opens the database in Notes.
struct PinnedDatabaseCards: View {
    @Environment(\.modelContext) private var context
    /// Re-read on every dashboard appearance; pins change rarely.
    @State private var pins: [(databaseID: UUID, viewID: UUID?)] = []

    var body: some View {
        ForEach(Array(pins.enumerated()), id: \.offset) { _, pin in
            PinnedDatabaseCard(databaseID: pin.databaseID, viewID: pin.viewID)
        }
        .onAppear { pins = PinStore.pinnedDBViews() }
    }
}

private struct PinnedDatabaseCard: View {
    let databaseID: UUID
    let viewID: UUID?

    @Environment(\.modelContext) private var context

    var body: some View {
        let store = DatabaseStore(context: context)
        let database = store.databaseNotes().first { $0.id == databaseID }

        if let database {
            let properties = store.fetchProperties(databaseNoteID: databaseID)
            let title = store.titleProperty(among: properties)
            let view = viewID.flatMap { id in store.views(of: database).first { $0.id == id } }
            let rows = store.fetchRows(databaseNoteID: databaseID)
            let values = Self.cellValues(store: store, properties: properties, rows: rows)
            let visible = store.apply(view, rows: rows, values: values, properties: properties)
            // The status-ish second line: first non-title column with content.
            let secondary = properties.first { $0.id != title?.id }

            DashboardCard(
                title: (database.title.isEmpty ? "Untitled" : database.title)
                    + (view.map { " · \($0.name)" } ?? ""),
                systemImage: "tablecells",
                content: {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    if visible.isEmpty {
                        EmptyStateLine(text: "No rows match this view.")
                    }
                    ForEach(visible.prefix(5)) { row in
                        Button {
                            NotificationCenter.default.post(
                                name: .unifyrRevealNote, object: nil, userInfo: ["id": databaseID]
                            )
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Text(store.rowTitle(row.id, titleProperty: title))
                                    .font(Theme.Font.cardBody)
                                    .lineLimit(1)
                                Spacer()
                                if let secondary {
                                    Text(store.displayText(values[row.id]?[secondary.id] ?? DBCellValue(), property: secondary))
                                        .font(Theme.Font.cardCaption)
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                },
                accessory: {
                    Text("\(visible.count)")
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            )
            .contextMenu {
                Button("Unpin from Dashboard") {
                    PinStore.toggle(databaseView: databaseID, viewID: viewID)
                }
            }
        }
    }

    private static func cellValues(
        store: DatabaseStore,
        properties: [DBProperty],
        rows: [DBRow]
    ) -> [UUID: [UUID: DBCellValue]] {
        var values: [UUID: [UUID: DBCellValue]] = [:]
        for row in rows {
            for property in properties {
                let cell = store.value(rowID: row.id, propertyID: property.id)
                if !cell.isEmpty { values[row.id, default: [:]][property.id] = cell }
            }
        }
        return values
    }
}

struct PinnedRemindersCard: View {
    @Environment(\.brokers) private var brokers
    @State private var pinnedIDs = PinStore.pinnedReminderIDs
    @State private var reminders: [ReminderSnapshot] = []

    var body: some View {
        // The .task/.onReceive live on a stable Group — attaching a copy to
        // each branch gives the branches distinct view identities, so every
        // empty↔populated flip re-fired the other branch's .task (double
        // broker fetch per transition).
        Group {
            if !reminders.isEmpty {
                DashboardCard(title: "Pinned Reminders", systemImage: "pin") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(reminders) { reminder in
                            row(reminder)
                        }
                    }
                }
            } else {
                // Invisible loader: the card appears once a pinned reminder loads.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .unifyrPinsChanged)) { _ in
            pinnedIDs = PinStore.pinnedReminderIDs
            Task { await load() }
        }
    }

    private func row(_ reminder: ReminderSnapshot) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .unifyrRevealReminder, object: nil, userInfo: ["id": reminder.id]
            )
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Button {
                    Task {
                        if reminder.isCompleted {
                            try? await brokers.eventKit.uncompleteReminder(id: reminder.id)
                        } else {
                            try? await brokers.eventKit.completeReminder(id: reminder.id)
                        }
                        await load()
                    }
                } label: {
                    Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(reminder.isCompleted ? Theme.Palette.success : Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(reminder.title)
                        .font(Theme.Font.cardBody)
                        .strikethrough(reminder.isCompleted)
                        .foregroundStyle(reminder.isCompleted ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                        .lineLimit(1)
                    if let due = reminder.dueDate {
                        // Due date on its own row, indented (per spec).
                        Text(due.formatted(date: .abbreviated, time: .shortened))
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(
                                !reminder.isCompleted && due < Date()
                                    ? Theme.Palette.danger
                                    : Theme.Palette.textSecondary
                            )
                            .padding(.leading, Theme.Spacing.md)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Unpin from Dashboard") { PinStore.toggle(reminder: reminder.id) }
        }
    }

    private func load() async {
        pinnedIDs = PinStore.pinnedReminderIDs
        guard !pinnedIDs.isEmpty else {
            reminders = []
            return
        }
        guard brokers.eventKit.remindersAuthorization == .authorized
                || brokers.eventKit.remindersAuthorization == .limited else {
            reminders = []
            return
        }
        // Direct per-id lookups — not a fetch of every reminder in every list.
        let all = (try? await brokers.eventKit.fetchReminders(ids: Array(pinnedIDs))) ?? []
        reminders = all
            .sorted { a, b in
                switch (a.dueDate, b.dueDate) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.title < b.title
                }
            }
    }
}
