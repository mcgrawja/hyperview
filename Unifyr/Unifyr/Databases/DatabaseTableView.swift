//
//  DatabaseTableView.swift
//  Unifyr
//
//  The table (grid) view of a database note. Hand-rolled from ScrollViews —
//  SwiftUI's Table can't do user-defined columns cross-platform — with fixed
//  per-kind column widths (§4.3 v1; no drag-resize yet).
//

import SwiftUI
import SwiftData

struct DatabaseTableView: View {
    let note: Note
    let properties: [DBProperty]
    let rows: [DBRow]
    /// rowID → propertyID → decoded cell.
    let values: [UUID: [UUID: DBCellValue]]
    let openRow: (DBRow) -> Void

    @Environment(\.modelContext) private var context

    @State private var renamingProperty: DBProperty?
    @State private var renameText = ""
    @State private var deletingProperty: DBProperty?
    @State private var deletingRow: DBRow?
    /// Relation properties need a target database picked before creation.
    @State private var choosingRelationTarget = false

    private var store: DatabaseStore { DatabaseStore(context: context) }
    private var titleProperty: DBProperty? { store.titleProperty(among: properties) }

    /// Live width while a header edge is being dragged (committed to the
    /// property's config — synced — on release). `start` anchors the drag.
    @State private var resizing: (id: UUID, start: CGFloat, width: CGFloat)?

    /// Stored width if the user resized the column, else the kind's default
    /// (title column anchors wider).
    private func width(of property: DBProperty) -> CGFloat {
        if let resizing, resizing.id == property.id { return resizing.width }
        if let stored = store.config(of: property).width { return max(80, CGFloat(stored)) }
        return property.id == titleProperty?.id ? 230 : property.propertyKind.columnWidth
    }

    private var tableWidth: CGFloat {
        properties.reduce(CGFloat(Self.openColumnWidth)) { $0 + width(of: $1) } + 44
    }

    /// Leading gutter holding each row's open-as-page button.
    private static let openColumnWidth: CGFloat = 32

    var body: some View {
        // GeometryReader + minWidth/minHeight: a two-axis ScrollView CENTERS
        // content smaller than the viewport — the table must hug top-leading.
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().overlay(Theme.Palette.separatorStrong)
                    ForEach(rows) { row in
                        rowView(row)
                        Divider().overlay(Theme.Palette.separator)
                    }
                    newRowButton
                }
                .frame(width: tableWidth, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xl)
                .frame(
                    minWidth: geo.size.width,
                    minHeight: geo.size.height,
                    alignment: .topLeading
                )
            }
        }
        .alert("Rename Property", isPresented: .init(
            get: { renamingProperty != nil },
            set: { if !$0 { renamingProperty = nil } }
        )) {
            TextField("Property name", text: $renameText)
            Button("Rename") {
                if let renamingProperty {
                    store.rename(renamingProperty, to: renameText, in: note)
                    try? context.save()
                }
                renamingProperty = nil
            }
            Button("Cancel", role: .cancel) { renamingProperty = nil }
        }
        .confirmationDialog(
            "Delete the \"\(deletingProperty?.name ?? "")\" property and all its values?",
            isPresented: .init(
                get: { deletingProperty != nil },
                set: { if !$0 { deletingProperty = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Property", role: .destructive) {
                if let deletingProperty {
                    store.deleteProperty(deletingProperty, in: note)
                    try? context.save()
                }
                deletingProperty = nil
            }
        }
        .confirmationDialog(
            "Delete this row and its page content?",
            isPresented: .init(
                get: { deletingRow != nil },
                set: { if !$0 { deletingRow = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Row", role: .destructive) {
                if let deletingRow {
                    store.deleteRow(deletingRow, in: note)
                    try? context.save()
                }
                deletingRow = nil
            }
        }
        .confirmationDialog(
            "Link to which database?",
            isPresented: $choosingRelationTarget,
            titleVisibility: .visible
        ) {
            ForEach(store.databaseNotes(excluding: note.id)) { target in
                Button(target.title.isEmpty ? "Untitled" : target.title) {
                    store.addProperty(
                        to: note,
                        kind: .relation,
                        name: target.title.isEmpty ? "Relation" : target.title,
                        config: DBPropertyConfig(relationTargetID: target.id)
                    )
                    try? context.save()
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.openColumnWidth, height: 1)
            ForEach(properties) { property in
                headerCell(property)
                    .frame(width: width(of: property), alignment: .leading)
                    .overlay(alignment: .trailing) { resizeGrip(property) }
            }
            addPropertyButton
        }
    }

    /// The draggable right edge of a column header (refinement pass).
    private func resizeGrip(_ property: DBProperty) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .overlay(
                Rectangle()
                    .fill(resizing?.id == property.id ? Theme.Palette.primary : Theme.Palette.separator)
                    .frame(width: resizing?.id == property.id ? 2 : 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // First tick anchors on the pre-drag width (width(of:)
                        // ignores `resizing` while the ids don't match yet).
                        let start = resizing?.id == property.id
                            ? resizing!.start
                            : width(of: property)
                        resizing = (property.id, start, max(80, start + value.translation.width))
                    }
                    .onEnded { _ in
                        guard let resizing, resizing.id == property.id else { return }
                        var config = store.config(of: property)
                        config.width = Double(resizing.width)
                        store.setConfig(config, on: property)
                        try? context.save()
                        self.resizing = nil
                    }
            )
    }

    private func headerCell(_ property: DBProperty) -> some View {
        Menu {
            Button("Rename…") {
                renameText = property.name
                renamingProperty = property
            }
            if property.id != titleProperty?.id {
                if property.propertyKind != .relation {
                    Menu("Type") {
                        ForEach(DBPropertyKind.convertible, id: \.rawValue) { kind in
                            Button {
                                store.changeKind(property, to: kind, in: note)
                                try? context.save()
                            } label: {
                                if kind == property.propertyKind {
                                    Label(kind.displayName, systemImage: "checkmark")
                                } else {
                                    Text(kind.displayName)
                                }
                            }
                        }
                    }
                }
                Divider()
            }
            Button("Move Left") {
                store.moveProperty(property, offset: -1, within: properties)
                try? context.save()
            }
            .disabled(properties.first?.id == property.id)
            Button("Move Right") {
                store.moveProperty(property, offset: 1, within: properties)
                try? context.save()
            }
            .disabled(properties.last?.id == property.id)
            if property.id != titleProperty?.id {
                Divider()
                Button("Delete Property", role: .destructive) {
                    deletingProperty = property
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: property.propertyKind.systemImage)
                    .font(.caption)
                Text(property.name)
                    .font(Theme.Font.cardCaption)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var addPropertyButton: some View {
        Menu {
            ForEach(DBPropertyKind.creatable, id: \.rawValue) { kind in
                Button {
                    if kind == .relation {
                        choosingRelationTarget = true
                    } else {
                        store.addProperty(to: note, kind: kind)
                        try? context.save()
                    }
                } label: {
                    Label(kind.displayName, systemImage: kind.systemImage)
                }
                .disabled(kind == .relation && store.databaseNotes(excluding: note.id).isEmpty)
            }
        } label: {
            Image(systemName: "plus")
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Add Property")
    }

    // MARK: Rows

    private func rowView(_ row: DBRow) -> some View {
        HStack(spacing: 0) {
            Button {
                openRow(row)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: Self.openColumnWidth, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open as page")

            ForEach(properties) { property in
                DatabaseCellEditor(
                    property: property,
                    config: store.config(of: property),
                    value: values[row.id]?[property.id] ?? DBCellValue(),
                    note: note
                ) { cell in
                    store.setValue(cell, rowID: row.id, propertyID: property.id, in: note)
                    try? context.save()
                }
                .font(Theme.Font.cardBody)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .frame(width: width(of: property), alignment: .leading)
            }
        }
        .contextMenu {
            Button("Open as Page") { openRow(row) }
            Divider()
            Button("Move Up") {
                store.moveRow(row, offset: -1, within: rows)
                try? context.save()
            }
            .disabled(rows.first?.id == row.id)
            Button("Move Down") {
                store.moveRow(row, offset: 1, within: rows)
                try? context.save()
            }
            .disabled(rows.last?.id == row.id)
            Divider()
            Button("Delete Row", role: .destructive) { deletingRow = row }
        }
    }

    private var newRowButton: some View {
        Button {
            store.addRow(to: note)
            try? context.save()
        } label: {
            Label("New Row", systemImage: "plus")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
