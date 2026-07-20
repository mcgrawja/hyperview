//
//  RemindersCard.swift
//  Unifyr
//
//  Phase 1 dashboard card over EventKitBroker (reminders). Reminders are a
//  separate TCC prompt from Calendar (§6), so this card gates independently.
//  Todo toggling routes through the broker (the future reminders_complete tool).
//

import SwiftUI

struct RemindersCard: View {
    @Environment(\.brokers) private var brokers

    @State private var reminders: [ReminderSnapshot] = []
    @State private var access: ModuleAccess = .needsPermission
    @State private var errorText: String?

    var body: some View {
        DashboardCard(title: "Due Soon", systemImage: "checklist", accent: Theme.Palette.primary) {
            content
        } accessory: {
            if access == .ready, !reminders.isEmpty {
                CountBadge(count: reminders.count, accent: Theme.Palette.primary)
            }
        }
        .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .needsPermission:
            ConnectPrompt(moduleName: "Reminders", systemImage: "checklist", accent: Theme.Palette.primary) {
                await connect()
            }
        case .blocked:
            BlockedPrompt(moduleName: "Reminders")
        case .ready:
            if let errorText {
                EmptyStateLine(text: errorText)
            } else if reminders.isEmpty {
                EmptyStateLine(text: "No reminders due soon.")
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(reminders) { reminder in
                        ReminderRow(reminder: reminder) { await complete(reminder) }
                    }
                }
            }
        }
    }

    private func start() async {
        access = ModuleAccess(brokers.eventKit.remindersAuthorization)
        guard access == .ready else { return }
        await load()
        await observe()
    }

    private func connect() async {
        do {
            try await brokers.eventKit.requestRemindersAccess()
            access = .ready
            await load()
            await observe()
        } catch {
            access = ModuleAccess(brokers.eventKit.remindersAuthorization)
        }
    }

    private func load() async {
        do {
            reminders = try await brokers.eventKit.fetchDueReminders()
            errorText = nil
        } catch {
            errorText = "Couldn't load your reminders."
        }
    }

    private func complete(_ reminder: ReminderSnapshot) async {
        do {
            try await brokers.eventKit.completeReminder(id: reminder.id)
            await load()
        } catch {
            errorText = "Couldn't update that reminder."
        }
    }

    private func observe() async {
        for await _ in brokers.eventKit.changes() {
            await load()
        }
    }
}

private struct ReminderRow: View {
    let reminder: ReminderSnapshot
    let onComplete: () async -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                Task { await onComplete() }
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reminder.isCompleted ? Theme.Palette.success : Theme.Palette.textSecondary)
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
                        .foregroundStyle(dueColor(due))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func dueColor(_ due: Date) -> Color {
        due < Date() ? Theme.Palette.danger : Theme.Palette.textSecondary
    }
}
