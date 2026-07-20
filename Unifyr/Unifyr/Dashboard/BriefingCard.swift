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
    @Environment(\.brokers) private var brokers
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
                briefingBody(text)
            case .failed(let message):
                EmptyStateLine(text: message)
            case .idle, .hidden:
                EmptyStateLine(text: "Your briefing will appear here.")
            }
        }
    }

    // MARK: Interactive briefing lines

    /// One parsed line of the briefing. Lines carrying a `[rem:…]` / `[mail:…]`
    /// tag render as interactive rows; everything else is static text.
    private struct BriefingLine: Identifiable {
        enum Kind {
            case plain, reminder(String), mail(String)
            var tagPrefix: String {
                switch self {
                case .reminder: return "rem:"
                case .mail: return "mail:"
                case .plain: return ""
                }
            }
        }
        let id: Int
        let display: String
        let kind: Kind
        let done: Bool
    }

    private func parseLines(_ text: String) -> [BriefingLine] {
        text.components(separatedBy: "\n").enumerated().map { index, raw in
            let kind: BriefingLine.Kind
            let ref: String?
            if let r = Self.tag(in: raw, prefix: "rem:") {
                kind = .reminder(r); ref = r
            } else if let r = Self.tag(in: raw, prefix: "mail:") {
                kind = .mail(r); ref = r
            } else {
                kind = .plain; ref = nil
            }
            // Strip the machine tag from what the user sees.
            var display = raw
            if let ref {
                display = display
                    .replacingOccurrences(of: "[\(kind.tagPrefix)\(ref)]", with: "")
                // Trim only trailing whitespace — leading indentation is layout.
                while display.hasSuffix(" ") { display.removeLast() }
            }
            return BriefingLine(id: index, display: display, kind: kind, done: raw.contains("☑"))
        }
    }

    private static func tag(in line: String, prefix: String) -> String? {
        guard let start = line.range(of: "[\(prefix)"),
              let end = line.range(of: "]", range: start.upperBound..<line.endIndex) else { return nil }
        return String(line[start.upperBound..<end.lowerBound])
    }

    @ViewBuilder
    private func briefingBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(parseLines(text)) { line in
                switch line.kind {
                case .plain:
                    Text(line.display.isEmpty ? " " : line.display)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .reminder(let id):
                    actionRow(line) {
                        // Checkbox completes the real reminder.
                        Task {
                            try? await brokers.eventKit.completeReminder(id: id)
                            service.markLineDone(ref: "rem:\(id)")
                        }
                    } onOpen: {
                        // Tapping the text reveals it in Reminders.
                        NotificationCenter.default.post(name: .unifyrOpenModule, object: nil, userInfo: ["module": "reminders"])
                        DeepLink.send(.unifyrOpenReminder, userInfo: ["id": id])
                    }
                case .mail(let id):
                    actionRow(line) {
                        // Checkbox marks the briefing item handled.
                        service.markLineDone(ref: "mail:\(id)")
                    } onOpen: {
                        guard let uuid = UUID(uuidString: id) else { return }
                        NotificationCenter.default.post(name: .unifyrOpenModule, object: nil, userInfo: ["module": "mail"])
                        DeepLink.send(.unifyrOpenMailMessage, userInfo: ["id": uuid])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Checkbox (complete) + tappable text (open). Done lines strike through.
    private func actionRow(_ line: BriefingLine, onComplete: @escaping () -> Void, onOpen: @escaping () -> Void) -> some View {
        // Split leading indent + checkbox from the content so the checkbox
        // becomes the button and the rest stays column-aligned.
        let content = line.display
            .replacingOccurrences(of: "☐ ", with: "")
            .replacingOccurrences(of: "☑ ", with: "")
            .trimmingCharacters(in: .whitespaces)
        let indent = line.display.prefix { $0 == " " }
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(String(indent))
                .font(.system(.body, design: .monospaced))
            Button {
                if !line.done { onComplete() }
            } label: {
                Image(systemName: line.done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(line.done ? Theme.Palette.success : Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(line.done)
            .help(line.done ? "Done" : "Mark done")
            Text(" ")
                .font(.system(.body, design: .monospaced))
            Button(action: onOpen) {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .strikethrough(line.done)
                    .foregroundStyle(line.done ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open")
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
