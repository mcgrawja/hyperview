//
//  DatabaseRowPage.swift
//  Unifyr
//
//  A database row opened as a page (the Notion move): title, a property form,
//  and the row's own block document in the real TipTap editor. The blocks are
//  the database note's Blocks scoped by `rowID` (§4.3), edited through the
//  same bridge as ordinary notes via an EditorDocument handle.
//

import SwiftUI
import SwiftData

struct DatabaseRowPage: View {
    let note: Note
    let row: DBRow
    let properties: [DBProperty]
    let values: [UUID: [UUID: DBCellValue]]
    let close: () -> Void

    @Environment(\.modelContext) private var context

    private var store: DatabaseStore { DatabaseStore(context: context) }
    private var titleProperty: DBProperty? { store.titleProperty(among: properties) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    close()
                } label: {
                    Label(note.title.isEmpty ? "Back" : note.title, systemImage: "chevron.left")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.md)

            // Title = the title property's cell, writ large.
            CommittingTextField(value: titleText, placeholder: "Untitled") { text in
                guard let titleProperty else { return }
                var cell = values[row.id]?[titleProperty.id] ?? DBCellValue()
                cell.text = text.isEmpty ? nil : text
                store.setValue(cell, rowID: row.id, propertyID: titleProperty.id, in: note)
                try? context.save()
            }
            .font(Theme.Font.dashboardTitle)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.sm)

            // The property form (everything but the title).
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(properties.filter { $0.id != titleProperty?.id }) { property in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                        Label(property.name, systemImage: property.propertyKind.systemImage)
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(width: 140, alignment: .leading)
                            .lineLimit(1)
                        DatabaseCellEditor(
                            property: property,
                            config: store.config(of: property),
                            value: values[row.id]?[property.id] ?? DBCellValue(),
                            note: note
                        ) { cell in
                            store.setValue(cell, rowID: row.id, propertyID: property.id, in: note)
                            try? context.save()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, Theme.Spacing.xxs)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)

            Divider().overlay(Theme.Palette.separator)
                .padding(.horizontal, Theme.Spacing.xl)

            // The row's page content, in the shared TipTap editor.
            NoteEditorWebView(document: EditorDocument(
                id: row.id,
                load: { [context] in
                    DatabaseStore(context: context).loadRowDocument(row, in: note)
                },
                save: { [context] document in
                    DatabaseStore(context: context).saveRowDocument(document, row: row, in: note)
                    try? context.save()
                }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.background)
    }

    private var titleText: String {
        guard let titleProperty else { return "" }
        return values[row.id]?[titleProperty.id]?.text ?? ""
    }
}
