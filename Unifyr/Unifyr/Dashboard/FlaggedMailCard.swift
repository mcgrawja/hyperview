//
//  FlaggedMailCard.swift
//  Unifyr
//
//  Dashboard card: flagged / follow-up emails across all accounts, from the
//  local mail cache. Tapping a row opens Mail on that message. The mail store
//  is a separate (non-CloudKit) container, so this reads it with its own
//  ModelContext rather than an @Query on the main context.
//

import SwiftUI
import SwiftData

struct FlaggedMailCard: View {
    @Environment(\.mailContainer) private var mailContainer

    @State private var items: [Item] = []

    struct Item: Identifiable {
        let id: UUID
        let subject: String
        let from: String
        let date: Date
    }

    var body: some View {
        DashboardCard(title: "Flagged", systemImage: "flag.fill", accent: Theme.Palette.warning) {
            content
        } accessory: {
            if !items.isEmpty {
                CountBadge(count: items.count, accent: Theme.Palette.warning)
            }
        }
        .task { load() }
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            EmptyStateLine(text: "No flagged email.")
        } else {
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(items) { item in
                    Button { open(item.id) } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "flag.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.warning)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(item.subject)
                                    .font(Theme.Font.cardBody)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .lineLimit(1)
                                Text("\(item.from) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(Theme.Font.cardCaption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() {
        guard let mailContainer else { items = []; return }
        let context = ModelContext(mailContainer)
        let accounts = (try? context.fetch(FetchDescriptor<MailAccount>())) ?? []
        let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.emailAddress) })
        // Predicate + sort + limit in the store — fetching the whole mail
        // cache to show 6 rows stalls the main actor on a big mailbox.
        var descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.isFlagged },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 6
        let messages = (try? context.fetch(descriptor)) ?? []
        items = messages
            .map { message in
                Item(
                    id: message.id,
                    subject: message.subject.isEmpty ? "(No Subject)" : message.subject,
                    from: message.fromName.isEmpty ? (message.fromAddress.isEmpty ? (names[message.accountID] ?? "?") : message.fromAddress) : message.fromName,
                    date: message.date
                )
            }
    }

    /// Switch to Mail and hand off through the DeepLink latch (no timer race).
    private func open(_ id: UUID) {
        NotificationCenter.default.post(name: .unifyrOpenModule, object: nil, userInfo: ["module": "mail"])
        DeepLink.send(.unifyrOpenMailMessage, userInfo: ["id": id])
    }
}
