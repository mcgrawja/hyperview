//
//  DatabaseBoardView.swift
//  Unifyr
//
//  The kanban view of a database note: one column per option of the grouping
//  select property (plus "No <property>"), cards draggable between columns.
//  The grouping choice is a database-level setting (Note.schemaJSON) so it
//  syncs; falling back to the first select property keeps the board usable
//  before anything is chosen.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DatabaseBoardView: View {
    let note: Note
    let properties: [DBProperty]
    let rows: [DBRow]
    let values: [UUID: [UUID: DBCellValue]]
    let groupProperty: DBProperty?
    let openRow: (DBRow) -> Void

    @Environment(\.modelContext) private var context

    private var store: DatabaseStore { DatabaseStore(context: context) }
    private var titleProperty: DBProperty? { store.titleProperty(among: properties) }
    private var options: [DBSelectOption] {
        groupProperty.map { store.config(of: $0).options ?? [] } ?? []
    }

    var body: some View {
        if let groupProperty {
            board(groupProperty)
        } else {
            // No select property to group by — offer to create the standard one.
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Board view groups rows by a Select property.")
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button("Add a Status Property") {
                    store.addProperty(
                        to: note,
                        kind: .select,
                        name: "Status",
                        config: DBPropertyConfig(options: [
                            DBSelectOption(name: "Not started", colorHex: "#7F838C"),
                            DBSelectOption(name: "In progress", colorHex: "#F2A65A"),
                            DBSelectOption(name: "Done", colorHex: "#3E8EF7"),
                        ])
                    )
                    try? context.save()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func board(_ groupProperty: DBProperty) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ForEach(options) { option in
                    column(
                        groupProperty: groupProperty,
                        option: option,
                        rows: rows(withOption: option.id, of: groupProperty)
                    )
                }
                column(
                    groupProperty: groupProperty,
                    option: nil,
                    rows: rows(withOption: nil, of: groupProperty)
                )
            }
            .padding(Theme.Spacing.lg)
        }
    }

    /// Rows whose group cell holds `optionID` (nil = un-grouped), in row order.
    private func rows(withOption optionID: UUID?, of groupProperty: DBProperty) -> [DBRow] {
        rows.filter { row in
            let selected = values[row.id]?[groupProperty.id]?.optionIDs?.first
            return selected == optionID
        }
    }

    // MARK: Columns

    private func column(groupProperty: DBProperty, option: DBSelectOption?, rows: [DBRow]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                if let option {
                    OptionChip(option: option)
                } else {
                    Text("No \(groupProperty.name)")
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Text("\(rows.count)")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.xs)

            ScrollView {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(rows) { row in
                        card(row)
                    }
                }
            }

            Button {
                let row = store.addRow(to: note, setting: option == nil ? nil : groupProperty, optionID: option?.id)
                try? context.save()
                openRow(row)
            } label: {
                Label("New", systemImage: "plus")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(Theme.Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.sm)
        .frame(width: 260, alignment: .top)
        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        // Dropping a card re-files its row into this column.
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let rowID = UUID(uuidString: raw) else { return false }
            var cell = values[rowID]?[groupProperty.id] ?? DBCellValue()
            cell.optionIDs = option.map { [$0.id] }
            store.setValue(cell, rowID: rowID, propertyID: groupProperty.id, in: note)
            try? context.save()
            return true
        }
    }

    // MARK: Cards

    private func card(_ row: DBRow) -> some View {
        let cells = values[row.id] ?? [:]
        // Secondary line: the first non-title, non-group property with content.
        let summary = properties.first { property in
            property.id != titleProperty?.id
                && property.id != groupProperty?.id
                && cells[property.id] != nil
        }.flatMap { property in
            cells[property.id].map { summaryText(property: property, cell: $0) }
        }

        return Button {
            openRow(row)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(store.rowTitle(row.id, titleProperty: titleProperty))
                    .font(Theme.Font.cardBody)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.sm)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(row.id.uuidString)
        .contextMenu {
            Button("Open as Page") { openRow(row) }
            Button("Delete Row", role: .destructive) {
                store.deleteRow(row, in: note)
                try? context.save()
            }
        }
    }

    private func summaryText(property: DBProperty, cell: DBCellValue) -> String {
        store.displayText(cell, property: property)
    }
}
