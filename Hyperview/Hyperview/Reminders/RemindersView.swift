//
//  RemindersView.swift
//  Hyperview
//
//  Reminders module, Apple-Reminders-style: one column per reminders list
//  (kanban layout), inline per-column quick-add, and a right-hand detail panel
//  where the selected reminder is fully editable — title, notes, due date,
//  priority, list, completion — all via EventKitBroker.
//

import SwiftUI

struct RemindersView: View {
    @Environment(\.brokers) private var brokers

    @State private var access: ModuleAccess = .needsPermission
    @State private var lists: [CalendarSnapshot] = []
    @State private var reminders: [ReminderSnapshot] = []
    @State private var showCompleted = false
    @State private var selectedID: String?

    var body: some View {
        Group {
            switch access {
            case .needsPermission:
                VStack {
                    ConnectPrompt(moduleName: "Reminders", systemImage: "checklist", accent: Theme.Palette.primary) {
                        await connect()
                    }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 380)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .blocked:
                VStack { BlockedPrompt(moduleName: "Reminders") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                content
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Reminders")
        .task { await start() }
        .toolbar {
            ToolbarItem {
                Toggle("Show Completed", isOn: $showCompleted)
                    .onChange(of: showCompleted) { _, _ in Task { await load() } }
            }
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    ForEach(lists) { list in
                        ReminderListColumn(
                            list: list,
                            reminders: reminders.filter { $0.listID == list.id },
                            showCompleted: showCompleted,
                            selectedID: $selectedID,
                            onToggle: { reminder in Task { await toggle(reminder) } },
                            onAdd: { title in Task { await add(title, to: list) } }
                        )
                    }
                    if lists.isEmpty {
                        EmptyStateLine(text: "No reminders lists found.")
                            .padding(Theme.Spacing.xl)
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let selected = reminders.first(where: { $0.id == selectedID }) {
                Divider().overlay(Theme.Palette.separator)
                ReminderDetailPanel(
                    reminder: selected,
                    lists: lists,
                    onSave: { draft in Task { await save(draft, original: selected) } },
                    onDelete: { Task { await delete(selected) } },
                    onClose: { selectedID = nil }
                )
                .frame(width: 300)
                .id(selected.id)
            }
        }
    }

    // MARK: Data

    private func start() async {
        access = ModuleAccess(brokers.eventKit.remindersAuthorization)
        guard access == .ready else { return }
        await load()
        for await _ in brokers.eventKit.changes() {
            await load()
        }
    }

    private func connect() async {
        do {
            try await brokers.eventKit.requestRemindersAccess()
            access = .ready
            await load()
        } catch {
            access = ModuleAccess(brokers.eventKit.remindersAuthorization)
        }
    }

    private func load() async {
        lists = (try? await brokers.eventKit.reminderLists()) ?? []
        reminders = (try? await brokers.eventKit.fetchReminders(
            BrokerQuery(includeCompleted: showCompleted)
        )) ?? []
        if let selectedID, !reminders.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    private func add(_ title: String, to list: CalendarSnapshot) async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        _ = try? await brokers.eventKit.createReminder(title: trimmed, listID: list.id)
        await load()
    }

    private func toggle(_ reminder: ReminderSnapshot) async {
        if reminder.isCompleted {
            try? await brokers.eventKit.uncompleteReminder(id: reminder.id)
        } else {
            try? await brokers.eventKit.completeReminder(id: reminder.id)
        }
        await load()
    }

    private func delete(_ reminder: ReminderSnapshot) async {
        try? await brokers.eventKit.deleteReminder(id: reminder.id)
        selectedID = nil
        await load()
    }

    private func save(_ draft: ReminderDraft, original: ReminderSnapshot) async {
        _ = try? await brokers.eventKit.updateReminder(
            id: original.id,
            title: draft.title,
            dueDate: draft.hasDueDate ? draft.dueDate : nil,
            clearDueDate: !draft.hasDueDate && original.dueDate != nil,
            notes: draft.notes,
            priority: draft.priority,
            listID: draft.listID == original.listID ? nil : draft.listID
        )
        if draft.isCompleted != original.isCompleted {
            if draft.isCompleted {
                try? await brokers.eventKit.completeReminder(id: original.id)
            } else {
                try? await brokers.eventKit.uncompleteReminder(id: original.id)
            }
        }
        await load()
    }
}

// MARK: - Column

private struct ReminderListColumn: View {
    let list: CalendarSnapshot
    let reminders: [ReminderSnapshot]
    let showCompleted: Bool
    @Binding var selectedID: String?
    let onToggle: (ReminderSnapshot) -> Void
    let onAdd: (String) -> Void

    @State private var newTitle = ""

    private var listColor: Color {
        list.colorHex.flatMap { Color(hexString: $0) } ?? Theme.Palette.primary
    }

    private var sorted: [ReminderSnapshot] {
        let active = reminders.filter { !$0.isCompleted }.sorted(by: byDue)
        guard showCompleted else { return active }
        return active + reminders.filter(\.isCompleted).sorted(by: byDue)
    }

    private func byDue(_ a: ReminderSnapshot, _ b: ReminderSnapshot) -> Bool {
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.title < b.title
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Circle().fill(listColor).frame(width: 10, height: 10)
                Text(list.title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(listColor)
                    .lineLimit(1)
                Spacer()
                Text("\(reminders.filter { !$0.isCompleted }.count)")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sorted) { reminder in
                        ReminderColumnRow(
                            reminder: reminder,
                            accent: listColor,
                            isSelected: reminder.id == selectedID,
                            onToggle: { onToggle(reminder) }
                        )
                        .onTapGesture { selectedID = reminder.id }
                    }
                    if sorted.isEmpty {
                        Text("No reminders")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.vertical, Theme.Spacing.sm)
                    }
                }
            }

            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "plus")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("New Reminder", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.cardBody)
                    .onSubmit {
                        onAdd(newTitle)
                        newTitle = ""
                    }
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .padding(Theme.Spacing.md)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

private struct ReminderColumnRow: View {
    let reminder: ReminderSnapshot
    let accent: Color
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Button(action: onToggle) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reminder.isCompleted ? accent : Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    if reminder.priority > 0 {
                        Text(String(repeating: "!", count: priorityBangs))
                            .font(Theme.Font.cardBody.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                    Text(reminder.title)
                        .font(Theme.Font.cardBody)
                        .strikethrough(reminder.isCompleted)
                        .foregroundStyle(reminder.isCompleted ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                        .lineLimit(2)
                }
                if let due = reminder.dueDate {
                    Text(due.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(!reminder.isCompleted && due < Date() ? Theme.Palette.danger : Theme.Palette.textSecondary)
                }
                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, Theme.Spacing.xs)
        .background(
            isSelected ? accent.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.control)
        )
        .contentShape(Rectangle())
    }

    /// Apple Reminders convention: low !, medium !!, high !!!.
    private var priorityBangs: Int {
        switch reminder.priority {
        case 1...4: return 3
        case 5: return 2
        default: return 1
        }
    }
}

// MARK: - Detail panel

/// Edit buffer for the detail panel — applied through the broker on Save.
struct ReminderDraft {
    var title: String
    var notes: String
    var hasDueDate: Bool
    var dueDate: Date
    var priority: Int
    var listID: String
    var isCompleted: Bool
}

private struct ReminderDetailPanel: View {
    let reminder: ReminderSnapshot
    let lists: [CalendarSnapshot]
    let onSave: (ReminderDraft) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var draft: ReminderDraft
    @State private var confirmingDelete = false

    init(
        reminder: ReminderSnapshot,
        lists: [CalendarSnapshot],
        onSave: @escaping (ReminderDraft) -> Void,
        onDelete: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.reminder = reminder
        self.lists = lists
        self.onSave = onSave
        self.onDelete = onDelete
        self.onClose = onClose
        _draft = State(initialValue: ReminderDraft(
            title: reminder.title,
            notes: reminder.notes ?? "",
            hasDueDate: reminder.dueDate != nil,
            dueDate: reminder.dueDate ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date(),
            priority: reminder.priority,
            listID: reminder.listID,
            isCompleted: reminder.isCompleted
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Details")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(Theme.Spacing.md)

            Divider().overlay(Theme.Palette.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Toggle("Completed", isOn: $draft.isCompleted)
                        .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Title")
                        TextField("Title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Notes")
                        TextEditor(text: $draft.notes)
                            .font(Theme.Font.cardBody)
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Due Date", isOn: $draft.hasDueDate)
                            .toggleStyle(.checkbox)
                        if draft.hasDueDate {
                            DatePicker("", selection: $draft.dueDate)
                                .labelsHidden()
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Priority")
                        Picker("", selection: $draft.priority) {
                            Text("None").tag(0)
                            Text("Low !").tag(9)
                            Text("Medium !!").tag(5)
                            Text("High !!!").tag(1)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("List")
                        Picker("", selection: $draft.listID) {
                            ForEach(lists) { list in
                                Text(list.title).tag(list.id)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .padding(Theme.Spacing.md)
            }

            Divider().overlay(Theme.Palette.separator)

            HStack {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete Reminder")
                Spacer()
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Palette.surface)
        .confirmationDialog("Delete this reminder?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Font.cardCaption.weight(.semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
    }
}
