//
//  RemindersView.swift
//  Hyperview
//
//  Full reminders module: quick-add bar, Overdue/Today/Upcoming/Someday
//  sections, complete/uncomplete toggles, delete — all via EventKitBroker.
//

import SwiftUI

struct RemindersView: View {
    @Environment(\.brokers) private var brokers

    @State private var access: ModuleAccess = .needsPermission
    @State private var reminders: [ReminderSnapshot] = []
    @State private var showCompleted = false
    @State private var quickTitle = ""
    @State private var quickDueEnabled = false
    @State private var quickDue = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()

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
        VStack(spacing: 0) {
            quickAdd
            Divider().overlay(Theme.Palette.separator)
            list
        }
    }

    private var quickAdd: some View {
        HStack(spacing: Theme.Spacing.sm) {
            TextField("Add a reminder…", text: $quickTitle)
                .textFieldStyle(.plain)
                .font(Theme.Font.cardBody)
                .padding(Theme.Spacing.sm)
                .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .onSubmit { Task { await add() } }
            Toggle("Due", isOn: $quickDueEnabled).toggleStyle(.checkbox)
            if quickDueEnabled {
                DatePicker("", selection: $quickDue).labelsHidden()
            }
            Button {
                Task { await add() }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(quickTitle.isEmpty ? Theme.Palette.textSecondary : Theme.Palette.primary)
            }
            .buttonStyle(.plain)
            .disabled(quickTitle.isEmpty)
        }
        .padding(Theme.Spacing.lg)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                let groups = grouped()
                if groups.allSatisfy(\.items.isEmpty) {
                    EmptyStateLine(text: "Nothing here — enjoy it.")
                }
                ForEach(groups, id: \.title) { group in
                    if !group.items.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text(group.title.uppercased())
                                .font(Theme.Font.cardCaption.weight(.semibold))
                                .foregroundStyle(group.title == "Overdue" ? Theme.Palette.danger : Theme.Palette.textSecondary)
                            ForEach(group.items) { reminder in
                                row(reminder)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ reminder: ReminderSnapshot) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
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
                HStack(spacing: Theme.Spacing.xs) {
                    if let due = reminder.dueDate {
                        Text(due.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(!reminder.isCompleted && due < Date() ? Theme.Palette.danger : Theme.Palette.textSecondary)
                    }
                    if !reminder.listTitle.isEmpty {
                        Text("· \(reminder.listTitle)").foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .font(Theme.Font.cardCaption)
            }
            Spacer()
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                Task {
                    try? await brokers.eventKit.deleteReminder(id: reminder.id)
                    await load()
                }
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
        reminders = (try? await brokers.eventKit.fetchReminders(
            BrokerQuery(includeCompleted: showCompleted)
        )) ?? []
    }

    private func add() async {
        let title = quickTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        quickTitle = ""
        _ = try? await brokers.eventKit.createReminder(
            title: title,
            dueDate: quickDueEnabled ? quickDue : nil
        )
        await load()
    }

    private func grouped() -> [(title: String, items: [ReminderSnapshot])] {
        let cal = Calendar.current
        let now = Date()
        let active = reminders.filter { !$0.isCompleted }
        let overdue = active.filter { ($0.dueDate ?? .distantFuture) < now && !cal.isDateInToday($0.dueDate ?? .distantFuture) }
        let today = active.filter { $0.dueDate.map { cal.isDateInToday($0) } ?? false }
        let upcoming = active.filter { ($0.dueDate ?? .distantPast) > now && !($0.dueDate.map { cal.isDateInToday($0) } ?? false) }
        let someday = active.filter { $0.dueDate == nil }
        var groups: [(String, [ReminderSnapshot])] = [
            ("Overdue", overdue), ("Today", today), ("Upcoming", upcoming), ("Someday", someday),
        ]
        if showCompleted {
            groups.append(("Completed", reminders.filter(\.isCompleted)))
        }
        return groups.map { (title: $0.0, items: $0.1) }
    }
}
