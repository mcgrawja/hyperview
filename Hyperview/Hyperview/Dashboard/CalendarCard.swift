//
//  CalendarCard.swift
//  Hyperview
//
//  Phase 1 dashboard card over EventKitBroker (calendar). Proves the card
//  protocol: read snapshots, render from Theme, request access lazily, and
//  refresh from the broker's change stream.
//

import SwiftUI

struct CalendarCard: View {
    @Environment(\.brokers) private var brokers

    @State private var events: [EventSnapshot] = []
    @State private var access: ModuleAccess = .needsPermission
    @State private var errorText: String?

    var body: some View {
        DashboardCard(title: "Today", systemImage: "calendar", accent: Theme.Palette.primary) {
            content
        } accessory: {
            if access == .ready, !events.isEmpty {
                CountBadge(count: events.count, accent: Theme.Palette.primary)
            }
        }
        .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .needsPermission:
            ConnectPrompt(moduleName: "Calendar", systemImage: "calendar", accent: Theme.Palette.primary) {
                await connect()
            }
        case .blocked:
            BlockedPrompt(moduleName: "Calendar")
        case .ready:
            if let errorText {
                EmptyStateLine(text: errorText)
            } else if events.isEmpty {
                EmptyStateLine(text: "Nothing on your calendar today.")
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(events) { EventRow(event: $0) }
                }
            }
        }
    }

    private func start() async {
        access = ModuleAccess(brokers.eventKit.calendarAuthorization)
        guard access == .ready else { return }
        await load()
        await observe()
    }

    private func connect() async {
        do {
            try await brokers.eventKit.requestAccess()
            access = .ready
            await load()
            await observe()
        } catch {
            access = ModuleAccess(brokers.eventKit.calendarAuthorization)
        }
    }

    private func load() async {
        do {
            events = try await brokers.eventKit.fetchTodayEvents()
            errorText = nil
        } catch {
            errorText = "Couldn't load your calendar."
        }
    }

    private func observe() async {
        for await _ in brokers.eventKit.changes() {
            await load()
        }
    }
}

private struct EventRow: View {
    let event: EventSnapshot

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(timeLabel)
                .font(Theme.Font.cardCaption.monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(event.title)
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var timeLabel: String {
        if event.isAllDay { return "all-day" }
        return event.start.formatted(date: .omitted, time: .shortened)
    }
}

/// Small pill showing a count; reused by the cards.
struct CountBadge: View {
    let count: Int
    var accent: Color = Theme.Palette.primary

    var body: some View {
        Text("\(count)")
            .font(Theme.Font.cardCaption.weight(.semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(accent.opacity(0.12), in: Capsule())
    }
}
