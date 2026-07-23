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

    /// Table vs board for the default "All" view — a per-device preference.
    @AppStorage private var viewModeRaw: String
    /// Which tab is active: "all" or a saved view's uuid — per-device.
    @AppStorage private var selectedViewRaw: String
    @State private var openRowID: UUID?
    /// Saved view being edited in the sheet.
    @State private var editingView: DBViewConfig?

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
        _selectedViewRaw = AppStorage(wrappedValue: "all", "db.view.\(note.id.uuidString)")
    }

    private var store: DatabaseStore { DatabaseStore(context: context) }

    private var savedViews: [DBViewConfig] { store.views(of: note) }

    /// The active saved view, or nil for "All".
    private var selectedView: DBViewConfig? {
        guard let id = UUID(uuidString: selectedViewRaw) else { return nil }
        return savedViews.first { $0.id == id }
    }

    private var viewMode: DatabaseViewMode {
        if let selectedView {
            return DatabaseViewMode(rawValue: selectedView.mode) ?? .table
        }
        return DatabaseViewMode(rawValue: viewModeRaw) ?? .table
    }

    /// Rows after the active view's filters and sorts.
    private var displayRows: [DBRow] {
        store.apply(selectedView, rows: rows, values: valuesByRow, properties: properties)
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

    /// Board grouping: the active view's override, else the synced database
    /// default, else the first select property.
    private var groupProperty: DBProperty? {
        let settings = store.settings(of: note)
        return selectProperties.first { $0.id == selectedView?.groupPropertyID }
            ?? selectProperties.first { $0.id == settings.boardGroupPropertyID }
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
        // An embed's ↗ deep-links to a specific row; the latch covers the
        // mount-after-navigation case, onReceive covers already-mounted.
        .task(id: note.id) {
            if let info = DeepLink.take(.unifyrOpenDBRow),
               info["db"] as? UUID == note.id,
               let rowID = info["row"] as? UUID {
                openRowID = rowID
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .unifyrOpenDBRow)) { notification in
            guard notification.userInfo?["db"] as? UUID == note.id,
                  let rowID = notification.userInfo?["row"] as? UUID else { return }
            DeepLink.take(.unifyrOpenDBRow)
            openRowID = rowID
        }
    }

    // No title row here — the Notes module's PageHost owns breadcrumbs, icon,
    // and title for every page kind (2026-07-22 Notion refocus).
    private var databaseBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // View tabs: All + saved views (Phase 4).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    viewTab(nil)
                    ForEach(savedViews) { view in
                        viewTab(view)
                    }
                    Menu {
                        Button("New Table View") { createView(mode: .table) }
                        Button("New Board View") { createView(mode: .board) }
                    } label: {
                        Image(systemName: "plus")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(Theme.Spacing.xs)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.xs)

            HStack(spacing: Theme.Spacing.md) {
                if let selectedView {
                    Button {
                        editingView = selectedView
                    } label: {
                        Label(filterSortSummary(selectedView), systemImage: "line.3.horizontal.decrease.circle")
                            .font(Theme.Font.cardCaption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.primary)
                    .help("Edit filters & sorts")
                } else {
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
                }

                if viewMode == .board, selectProperties.count > 1, selectedView == nil {
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

                Text(rowCountLabel)
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
                    rows: displayRows,
                    values: valuesByRow
                ) { row in
                    openRowID = row.id
                }
            case .board:
                DatabaseBoardView(
                    note: note,
                    properties: properties,
                    rows: displayRows,
                    values: valuesByRow,
                    groupProperty: groupProperty
                ) { row in
                    openRowID = row.id
                }
            }
        }
        .sheet(item: $editingView) { view in
            DatabaseViewEditor(
                note: note,
                properties: properties,
                initial: view,
                onSave: { updated in
                    store.upsertView(updated, on: note)
                    try? context.save()
                },
                onDelete: {
                    store.deleteView(view.id, on: note)
                    try? context.save()
                    selectedViewRaw = "all"
                }
            )
        }
    }

    private var rowCountLabel: String {
        let visible = displayRows.count
        if visible != rows.count { return "\(visible) of \(rows.count) rows" }
        return "\(visible) row\(visible == 1 ? "" : "s")"
    }

    private func filterSortSummary(_ view: DBViewConfig) -> String {
        let filters = view.filters?.count ?? 0
        let sorts = view.sorts?.count ?? 0
        var parts: [String] = []
        if filters > 0 { parts.append("\(filters) filter\(filters == 1 ? "" : "s")") }
        if sorts > 0 { parts.append("\(sorts) sort\(sorts == 1 ? "" : "s")") }
        return parts.isEmpty ? "Filter & Sort" : parts.joined(separator: " · ")
    }

    private func viewTab(_ view: DBViewConfig?) -> some View {
        let isActive = selectedView?.id == view?.id
        return Button {
            selectedViewRaw = view?.id.uuidString ?? "all"
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: view.flatMap { DatabaseViewMode(rawValue: $0.mode) }?.systemImage ?? "tray.full")
                    .font(.caption2)
                Text(view?.name ?? "All")
                    .font(Theme.Font.cardCaption)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                isActive ? Theme.Palette.primary.softFill(0.14) : Color.clear,
                in: Capsule()
            )
            .foregroundStyle(isActive ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let view {
                Button("Edit View…") { editingView = view }
                Divider()
                Button("Delete View", role: .destructive) {
                    store.deleteView(view.id, on: note)
                    try? context.save()
                    if selectedView?.id == view.id { selectedViewRaw = "all" }
                }
            }
        }
    }

    private func createView(mode: DatabaseViewMode) {
        var view = DBViewConfig()
        view.name = mode == .table ? "Table view" : "Board view"
        view.mode = mode.rawValue
        store.upsertView(view, on: note)
        try? context.save()
        selectedViewRaw = view.id.uuidString
        editingView = view
    }
}
