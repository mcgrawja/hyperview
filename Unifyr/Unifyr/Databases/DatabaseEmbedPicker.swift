//
//  DatabaseEmbedPicker.swift
//  Unifyr
//
//  "/Linked database" picker (Phase 4): choose a database — or one of its
//  saved views — to embed in the current page. The choice goes back to the
//  editor bridge as an insertDBEmbed notification (posted by the caller).
//

import SwiftUI
import SwiftData

struct DatabaseEmbedPicker: View {
    /// (databaseID, viewID, title, emoji)
    let onPick: (UUID, UUID?, String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var query = ""

    private var store: DatabaseStore { DatabaseStore(context: context) }

    private var databases: [Note] {
        let all = store.databaseNotes()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            ($0.title.isEmpty ? "Untitled" : $0.title).localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("Search databases…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(Theme.Spacing.md)

            Divider().overlay(Theme.Palette.separator)

            if databases.isEmpty {
                EmptyStateLine(text: "No databases yet — create one from the Notes list.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(databases) { database in
                        row(database, view: nil)
                        ForEach(store.views(of: database)) { view in
                            row(database, view: view)
                                .padding(.leading, Theme.Spacing.lg)
                        }
                    }
                }
                .listStyle(.plain)
            }

            Divider().overlay(Theme.Palette.separator)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Spacing.md)
        }
        .frame(width: 400, height: 440)
        .background(Theme.Palette.background)
    }

    private func row(_ database: Note, view: DBViewConfig?) -> some View {
        Button {
            onPick(
                database.id,
                view?.id,
                database.title.isEmpty ? "Untitled" : database.title,
                database.emoji
            )
            dismiss()
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                if let view {
                    Image(systemName: DatabaseViewMode(rawValue: view.mode)?.systemImage ?? "tablecells")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text(view.name)
                        .font(Theme.Font.cardBody)
                } else {
                    Text(database.emoji ?? "📊")
                    Text(database.title.isEmpty ? "Untitled" : database.title)
                        .font(Theme.Font.cardBody)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
