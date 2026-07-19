//
//  AskClaudeCard.swift
//  Unifyr
//
//  Dashboard card: a one-line prompt box that hands the question to the Claude
//  chat and switches to that module. The chat controller is app-level, so the
//  message is delivered whether or not the module is on screen yet.
//

import SwiftUI

struct AskClaudeCard: View {
    @Environment(\.claudeChat) private var chat

    @State private var text = ""

    var body: some View {
        DashboardCard(title: "Ask Claude", systemImage: "sparkles", accent: Theme.Palette.claude) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Ask about your day, mail, or notes — this opens the chat.")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("Ask Claude…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.cardBody)
                        .lineLimit(1...3)
                        .padding(Theme.Spacing.sm)
                        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .onSubmit(ask)
                    Button(action: ask) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isEmpty ? Theme.Palette.textSecondary : Theme.Palette.claude)
                    }
                    .buttonStyle(.plain)
                    .disabled(isEmpty)
                    .help("Ask")
                }
            }
        }
    }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ask() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = ""
        NotificationCenter.default.post(name: .hyperviewOpenModule, object: nil, userInfo: ["module": "claude"])
        chat?.send(trimmed)
    }
}
