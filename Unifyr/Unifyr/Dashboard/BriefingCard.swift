//
//  BriefingCard.swift
//  Unifyr
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
        stateContent
            .task {
                if let mcp { service.attach(mcp: mcp) }
                await service.refreshIfStale()
            }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch service.state {
        case .hidden:
            // NOT EmptyView — SwiftUI never runs .task on a view with no
            // rendered output, which would leave the key check unreached.
            Color.clear.frame(height: 0)
        default:
            card
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
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let weather = service.weather {
                WeatherStrip(weather: weather)
                Divider().overlay(Theme.Palette.separator)
            }
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
                    .font(.system(.body, design: .monospaced))
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
}

/// The native hourly weather strip: emoji, rain %, temperature per slot, with
/// the day's hi/lo and any significant concerns.
private struct WeatherStrip: View {
    let weather: DayWeather

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(weather.slots) { slot in
                    VStack(spacing: Theme.Spacing.xxs) {
                        Text(slot.emoji).font(.title3)
                        Text("\(slot.rainPercent)%")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(slot.rainPercent >= 50 ? Theme.Palette.primary : Theme.Palette.textSecondary)
                        Text("\(slot.tempF)°")
                            .font(Theme.Font.cardCaption.weight(.medium))
                        Text(slot.label)
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: Theme.Spacing.md) {
                Text("\(weather.locationName) · H \(weather.hiF)° / L \(weather.loF)°")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if !weather.concerns.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(weather.concerns.joined(separator: " / "))
                    }
                    .font(Theme.Font.cardCaption.weight(.medium))
                    .foregroundStyle(Theme.Palette.danger)
                }
                Spacer()
            }
        }
    }
}
