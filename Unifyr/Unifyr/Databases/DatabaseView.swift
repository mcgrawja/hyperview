//
//  DatabaseView.swift
//  Unifyr
//
//  "Unifyr 1.5: Databases" — the detail view for a Note with kind == .database.
//  Owns the @Query-driven data (properties/rows/values), the table|board
//  switcher (a per-device preference), and the open-row-as-page overlay.
//

import SwiftUI
import SwiftData

nonisolated enum DatabaseViewMode: String, CaseIterable {
    case table
    case board

    var displayName: String {
        switch self {
        case .table: "Table"
        case .board: "Board"
        }
    }

    var systemImage: String {
        switch self {
        case .table: "tablecells"
        case .board: "square.grid.3x1.below.line.grid.1x2"
        }
    }
}

struct DatabaseView: View {
    @Environment(\.modelContext) private var context
    @Bindable var note: Note

    @Query private var properties: [DBProperty]
    @Query private var rows: [DBRow]
    // All values, narrowed in `valuesByRow`: DBValue→row membership can't be
    // expressed in a #Predicate (no set-contains), and personal-scale data
    // makes the in-memory pass cheap.
    @Query private var allValues: [DBValue]

    /// Table vs board — a per-device view preference (like folder collapse),
    /// NOT synced state.
    @AppStorage private var viewModeRaw: String
    @State private var openRowID: UUID?

    init(note: Note) {
        self.note = note
        let id: UUID? = note.id
        _properties = Query(
            filter: #Predicate<DBProperty> { $0.databaseNoteID == id },
            sort: \DBProperty.sortKey
        )
        _rows = Query(
            filter: #Predicate<DBRow> { $0.databaseNoteID == id },
            sort: \DBRow.sortKey
        )
        _allValues = Query()
        _viewModeRaw = AppStorage(wrappedValue: DatabaseViewMode.table.rawValue, "db.viewMode.\(note.id.uuidString)")
    }

    private var store: DatabaseStore { DatabaseStore(context: context) }

    private var viewMode: DatabaseViewMode {
        get { DatabaseViewMode(rawValue: viewModeRaw) ?? .table }
    }

    /// rowID → propertyID → decoded cell, for this database's rows only.
    private var valuesByRow: [UUID: [UUID: DBCellValue]] {
        let rowIDs = Set(rows.map(\.id))
        var result: [UUID: [UUID: DBCellValue]] = [:]
        for value in allValues {
            guard let rowID = value.rowID, rowIDs.contains(rowID),
                  let propertyID = value.propertyID else { continue }
            result[rowID, default: [:]][propertyID] = DBCellValue.decode(value.valueJSON)
        }
        return result
    }

    private var selectProperties: [DBProperty] {
        properties.filter { $0.propertyKind == .select }
    }

    /// Board grouping: the synced setting when it still resolves, else the
    /// first select property.
    private var groupProperty: DBProperty? {
        let settings = store.settings(of: note)
        return selectProperties.first { $0.id == settings.boardGroupPropertyID }
            ?? selectProperties.first
    }

    private var openRow: DBRow? {
        openRowID.flatMap { id in rows.first { $0.id == id } }
    }

    var body: some View {
        Group {
            if let openRow {
                DatabaseRowPage(
                    note: note,
                    row: openRow,
                    properties: properties,
                    values: valuesByRow
                ) {
                    openRowID = nil
                }
            } else {
                databaseBody
            }
        }
        .background(Theme.Palette.background)
    }

    private var databaseBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                TextField("Untitled", text: $note.title)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.dashboardTitle)
                    .onChange(of: note.title) { _, _ in note.modifiedAt = Date() }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.lg)

            HStack(spacing: Theme.Spacing.md) {
                Picker("View", selection: .init(
                    get: { viewMode },
                    set: { viewModeRaw = $0.rawValue }
                )) {
                    ForEach(DatabaseViewMode.allCases, id: \.rawValue) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if viewMode == .board, selectProperties.count > 1 {
                    Menu {
                        ForEach(selectProperties) { property in
                            Button {
                                var settings = store.settings(of: note)
                                settings.boardGroupPropertyID = property.id
                                store.setSettings(settings, on: note)
                                try? context.save()
                            } label: {
                                if property.id == groupProperty?.id {
                                    Label(property.name, systemImage: "checkmark")
                                } else {
                                    Text(property.name)
                                }
                            }
                        }
                    } label: {
                        Label("Group: \(groupProperty?.name ?? "—")", systemImage: "square.grid.3x1.below.line.grid.1x2")
                            .font(Theme.Font.cardCaption)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Spacer()

                Text("\(rows.count) row\(rows.count == 1 ? "" : "s")")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.sm)

            Divider().overlay(Theme.Palette.separator)

            switch viewMode {
            case .table:
                DatabaseTableView(
                    note: note,
                    properties: properties,
                    rows: rows,
                    values: valuesByRow
                ) { row in
                    openRowID = row.id
                }
            case .board:
                DatabaseBoardView(
                    note: note,
                    properties: properties,
                    rows: rows,
                    values: valuesByRow,
                    groupProperty: groupProperty
                ) { row in
                    openRowID = row.id
                }
            }
        }
    }
}
