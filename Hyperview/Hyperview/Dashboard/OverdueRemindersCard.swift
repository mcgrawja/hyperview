//
//  OverdueRemindersCard.swift
//  Unifyr
//
//  Dashboard card: reminders whose due date has passed and are still open.
//  Distinct from "Due Soon" — this is the "you're behind on these" glance.
//

import SwiftUI

struct OverdueRemindersCard: View {
    @Environment(\.brokers) private var brokers

    @State private var reminders: [ReminderSnapshot] = []
    @State private var access: ModuleAccess = .needsPermission

    var body: some View {
        DashboardCard(title: "Overdue", systemImage: "exclamationmark.circle", accent: Theme.Palette.danger) {
            content
        } accessory: {
            if access == .ready, !reminders.isEmpty {
                CountBadge(count: reminders.count, accent: Theme.Palette.danger)
            }
        }
        .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .needsPermission:
            ConnectPrompt(moduleName: "Reminders", systemImage: "checklist", accent: Theme.Palette.danger) {
                await connect()
            }
        case .blocked:
            BlockedPrompt(moduleName: "Reminders")
        case .ready:
            if reminders.isEmpty {
                EmptyStateLine(text: "Nothing overdue — you're caught up.")
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(reminders) { reminder in
                        HStack(spacing: Theme.Spacing.sm) {
                            Button { Task { await complete(reminder) } } label: {
                                Image(systemName: "circle")
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(reminder.title)
                                    .font(Theme.Font.cardBody)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .lineLimit(1)
                                if let due = reminder.dueDate {
                                    Text(due.formatted(date: .abbreviated, time: .shortened))
                                        .font(Theme.Font.cardCaption)
                                        .foregroundStyle(Theme.Palette.danger)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func start() async {
        access = ModuleAccess(brokers.eventKit.remindersAuthorization)
        guard access == .ready else { return }
        await load()
        for await _ in brokers.eventKit.changes() { await load() }
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
        // Wide window so long-overdue items surface (the default only reaches a
        // week back); then keep only those actually past due.
        let all = (try? await brokers.eventKit.fetchDueReminders(within: 365 * 24 * 60 * 60)) ?? []
        let now = Date()
        reminders = all
            .filter { ($0.dueDate ?? .distantFuture) < now }
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
    }

    private func complete(_ reminder: ReminderSnapshot) async {
        try? await brokers.eventKit.completeReminder(id: reminder.id)
        await load()
    }
}
