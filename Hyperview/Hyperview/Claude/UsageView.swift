//
//  UsageView.swift
//  Hyperview
//
//  Cost/usage pane like console.anthropic.com's cost page, built from the
//  local UsageLedger (every API call Hyperview makes: chat + briefings).
//  Loads only when opened or when Refresh is clicked — never in the
//  background. Dollar figures are list-price ESTIMATES; the Anthropic console
//  is the billing ground truth.
//

import SwiftUI

struct UsageView: View {
    @State private var entries: [UsageEntry] = []
    @State private var loadedAt: Date?
    @State private var confirmingClear = false

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                summaryCards
                modelBreakdown
                dailyList
                footer
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { refresh() }
        .confirmationDialog("Clear the local usage history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                UsageLedger.clear()
                refresh()
            }
        }
    }

    private func refresh() {
        entries = UsageLedger.entries()
        loadedAt = Date()
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("API Usage")
                    .font(Theme.Font.cardTitle)
                Text("Every Anthropic API call Hyperview has made (chat + daily briefings). Costs are list-price estimates — the Anthropic console is the billing source of truth.")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let loadedAt {
                Text("as of \(loadedAt.formatted(date: .omitted, time: .shortened))")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var summaryCards: some View {
        let now = Date()
        let today = entries.filter { calendar.isDateInToday($0.date) }
        let week = entries.filter { $0.date > now.addingTimeInterval(-7 * 86_400) }
        let month = entries.filter { $0.date > now.addingTimeInterval(-30 * 86_400) }
        return HStack(spacing: Theme.Spacing.md) {
            summaryCard("Today", entries: today)
            summaryCard("Last 7 Days", entries: week)
            summaryCard("Last 30 Days", entries: month)
        }
    }

    private func summaryCard(_ title: String, entries: [UsageEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Theme.Font.cardCaption.weight(.semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(dollars(entries.reduce(0) { $0 + UsageLedger.cost(of: $1) }))
                .font(Theme.Font.metricNumber)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("\(entries.count) calls · \(tokenTotal(entries)) tokens")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    @ViewBuilder
    private var modelBreakdown: some View {
        let byModel = Dictionary(grouping: entries, by: \.model)
            .map { (model: $0.key, entries: $0.value) }
            .sorted {
                $0.entries.reduce(0.0) { $0 + UsageLedger.cost(of: $1) }
                    > $1.entries.reduce(0.0) { $0 + UsageLedger.cost(of: $1) }
            }
        if !byModel.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("BY MODEL — verify what you're actually using")
                    .font(Theme.Font.cardCaption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                ForEach(byModel, id: \.model) { group in
                    HStack {
                        Text(UsageLedger.displayName(for: group.model))
                            .font(Theme.Font.cardBody.weight(.medium))
                        Spacer()
                        Text("\(group.entries.count) calls")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Text(tokenTotal(group.entries) + " tok")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(width: 90, alignment: .trailing)
                        Text(dollars(group.entries.reduce(0) { $0 + UsageLedger.cost(of: $1) }))
                            .font(Theme.Font.cardBody.weight(.semibold))
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    Divider().overlay(Theme.Palette.separator)
                }
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
    }

    @ViewBuilder
    private var dailyList: some View {
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
            .map { (day: $0.key, entries: $0.value) }
            .sorted { $0.day > $1.day }
            .prefix(14)
        if !byDay.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("RECENT DAYS")
                    .font(Theme.Font.cardCaption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                ForEach(Array(byDay), id: \.day) { group in
                    HStack {
                        Text(group.day.formatted(date: .abbreviated, time: .omitted))
                            .font(Theme.Font.cardBody)
                        Spacer()
                        // Which model(s) that day — the "was that Opus?" check.
                        Text(daySummary(group.entries))
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Text(dollars(group.entries.reduce(0) { $0 + UsageLedger.cost(of: $1) }))
                            .font(Theme.Font.cardBody.weight(.semibold))
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    Divider().overlay(Theme.Palette.separator)
                }
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        } else {
            EmptyStateLine(text: "No API calls recorded yet. Usage from before this feature shipped isn't included — check the Anthropic console for history.")
        }
    }

    private var footer: some View {
        HStack {
            Link("Open Anthropic Console Cost Page", destination: URL(string: "https://platform.claude.com/cost")!)
                .font(Theme.Font.cardCaption)
            Spacer()
            Button("Clear History…", role: .destructive) { confirmingClear = true }
                .buttonStyle(.plain)
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.danger)
        }
    }

    // MARK: Formatting

    private func dollars(_ value: Double) -> String {
        value < 0.005 && value > 0 ? "<$0.01" : String(format: "$%.2f", value)
    }

    private func tokenTotal(_ entries: [UsageEntry]) -> String {
        let total = entries.reduce(0) { $0 + $1.input + $1.output + $1.cacheRead + $1.cacheWrite }
        if total >= 1_000_000 { return String(format: "%.1fM", Double(total) / 1_000_000) }
        if total >= 1_000 { return String(format: "%.1fK", Double(total) / 1_000) }
        return "\(total)"
    }

    private func daySummary(_ entries: [UsageEntry]) -> String {
        let models = Dictionary(grouping: entries, by: \.model)
            .map { "\(UsageLedger.displayName(for: $0.key)) ×\($0.value.count)" }
            .sorted()
        return models.joined(separator: " · ")
    }
}
