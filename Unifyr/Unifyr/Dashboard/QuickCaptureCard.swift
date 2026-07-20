//
//  QuickCaptureCard.swift
//  Unifyr
//
//  Dashboard card: jot a note or add a reminder without leaving the dashboard.
//  Notes go to the main (CloudKit) store via NotesStore; reminders go through
//  the EventKit broker.
//

import SwiftUI
import SwiftData

struct QuickCaptureCard: View {
    @Environment(\.modelContext) private var notesContext
    @Environment(\.brokers) private var brokers

    @State private var text = ""
    @State private var mode: Mode = .note
    @State private var confirmation: String?

    enum Mode: String, CaseIterable, Identifiable {
        case note = "Note"
        case reminder = "Reminder"
        var id: String { rawValue }
    }

    var body: some View {
        DashboardCard(title: "Quick Capture", systemImage: "square.and.pencil", accent: Theme.Palette.primary) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Picker("Capture as", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: Theme.Spacing.sm) {
                    TextField(mode == .note ? "New note…" : "New reminder…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.cardBody)
                        .lineLimit(1...3)
                        .padding(Theme.Spacing.sm)
                        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(text.trimmedIsEmpty ? Theme.Palette.textSecondary : Theme.Palette.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.trimmedIsEmpty)
                    .help("Add")
                }

                if let confirmation {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: "checkmark.circle")
                        Text(confirmation)
                    }
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.success)
                    .transition(.opacity)
                }
            }
        }
    }

    private func add() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = ""
        switch mode {
        case .note:
            let store = NotesStore(context: notesContext)
            _ = store.createNote(title: String(trimmed.prefix(120)))
            try? notesContext.save()
            confirm("Note added")
        case .reminder:
            Task {
                _ = try? await brokers.eventKit.createReminder(title: trimmed, dueDate: nil, notes: nil)
                confirm("Reminder added")
            }
        }
    }

    private func confirm(_ message: String) {
        withAnimation { confirmation = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { confirmation = nil }
        }
    }
}

private extension String {
    var trimmedIsEmpty: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
