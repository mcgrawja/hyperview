//
//  BriefingCard.swift
//  Hyperview
//
//  Auto-generated morning briefing on the dashboard (Phase 5 follow-on).
//  Renders only when an API key exists; generates once per day automatically,
//  with a manual refresh. Orange accent = AI surface (D11).
//

import SwiftUI

struct BriefingCard: View {
    @Environment(\.mcp) private var mcp
    @State private var service = BriefingService()

    var body: some View {
        Group {
            switch service.state {
            case .hidden:
                EmptyView()
            default:
                card
            }
        }
        .task {
            if let mcp { service.attach(mcp: mcp) }
            await service.refreshIfStale()
        }
    }

    private var card: some View {
        DashboardCard(title: "Today's Briefing", systemImage: "sparkles", accent: Theme.Palette.claude) {
            content
        } accessory: {
            Button {
                Task { await service.generate() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Regenerate briefing")
            .disabled(service.state == .generating)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .generating:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Claude is reading your day…")
                    .font(Theme.Font.cardBody)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        case .ready(let text):
            Text(text)
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            EmptyStateLine(text: message)
        case .idle, .hidden:
            EmptyStateLine(text: "Your briefing will appear here.")
        }
    }
}
