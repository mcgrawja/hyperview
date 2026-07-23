//
//  DatabaseViewEditor.swift
//  Unifyr
//
//  The saved-view editor sheet (Phase 4): name, mode, board grouping,
//  AND-combined filters, ordered sorts. Edits a local copy; Save writes it
//  back through DatabaseStore.upsertView.
//

import SwiftUI
import SwiftData

struct DatabaseViewEditor: View {
    let note: Note
    let properties: [DBProperty]
    let initial: DBViewConfig
    let onSave: (DBViewConfig) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var draft: DBViewConfig

    init(
        note: Note,
        properties: [DBProperty],
        initial: DBViewConfig,
        onSave: @escaping (DBViewConfig) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.note = note
        self.properties = properties
        self.initial = initial
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: initial)
    }

    private var store: DatabaseStore { DatabaseStore(context: context) }
    private var selectProperties: [DBProperty] {
        properties.filter { $0.propertyKind == .select }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit View")
                .font(Theme.Font.cardTitle)
                .padding(Theme.Spacing.lg)

            Divider().overlay(Theme.Palette.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    HStack(spacing: Theme.Spacing.md) {
                        TextField("View name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        Picker("Mode", selection: $draft.mode) {
                            ForEach(DatabaseViewMode.allCases, id: \.rawValue) { mode in
                                Label(mode.displayName, systemImage: mode.systemImage).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }

                    if draft.mode == DatabaseViewMode.calendar.rawValue {
                        let dateProperties = properties.filter { $0.propertyKind == .date }
                        if dateProperties.isEmpty {
                            Text("Add a Date property to use a calendar view.")
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        } else {
                            Picker("Date property", selection: .init(
                                get: { draft.datePropertyID ?? dateProperties.first?.id },
                                set: { draft.datePropertyID = $0 }
                            )) {
                                ForEach(dateProperties) { property in
                                    Text(property.name).tag(Optional(property.id))
                                }
                            }
                            .fixedSize()
                        }
                    }

                    if draft.mode == DatabaseViewMode.board.rawValue, !selectProperties.isEmpty {
                        Picker("Group by", selection: .init(
                            get: { draft.groupPropertyID ?? selectProperties.first?.id },
                            set: { draft.groupPropertyID = $0 }
                        )) {
                            ForEach(selectProperties) { property in
                                Text(property.name).tag(Optional(property.id))
                            }
                        }
                        .fixedSize()
                    }

                    // MARK: Filters

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Filters — rows must match all")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        ForEach(Array((draft.filters ?? []).enumerated()), id: \.element.id) { index, filter in
                            filterRow(filter, at: index)
                        }
                        Button {
                            var filters = draft.filters ?? []
                            var filter = DBFilter()
                            let property = properties.first
                            filter.propertyID = property?.id
                            if let property {
                                filter.filterOp = DBFilterOp.valid(for: property.propertyKind).first ?? .contains
                            }
                            filters.append(filter)
                            draft.filters = filters
                        } label: {
                            Label("Add Filter", systemImage: "plus")
                                .font(Theme.Font.cardCaption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.primary)
                    }

                    // MARK: Sorts

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Sorts — applied in order")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        ForEach(Array((draft.sorts ?? []).enumerated()), id: \.element.id) { index, sort in
                            sortRow(sort, at: index)
                        }
                        Button {
                            var sorts = draft.sorts ?? []
                            var sort = DBSort()
                            sort.propertyID = properties.first?.id
                            sorts.append(sort)
                            draft.sorts = sorts
                        } label: {
                            Label("Add Sort", systemImage: "plus")
                                .font(Theme.Font.cardCaption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.primary)
                    }
                }
                .padding(Theme.Spacing.lg)
            }

            Divider().overlay(Theme.Palette.separator)

            HStack {
                Button("Delete View", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var cleaned = draft
                    if cleaned.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        cleaned.name = "View"
                    }
                    if cleaned.filters?.isEmpty == true { cleaned.filters = nil }
                    if cleaned.sorts?.isEmpty == true { cleaned.sorts = nil }
                    onSave(cleaned)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.primary)
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(Theme.Palette.background)
    }

    // MARK: Filter row

    private func filterRow(_ filter: DBFilter, at index: Int) -> some View {
        let property = properties.first { $0.id == filter.propertyID }
        return HStack(spacing: Theme.Spacing.sm) {
            // Property
            Picker("Property", selection: .init(
                get: { filter.propertyID },
                set: { newID in
                    updateFilter(at: index) { f in
                        f.propertyID = newID
                        // The old op may be invalid for the new kind.
                        if let p = properties.first(where: { $0.id == newID }),
                           !DBFilterOp.valid(for: p.propertyKind).contains(f.filterOp) {
                            f.filterOp = DBFilterOp.valid(for: p.propertyKind).first ?? .contains
                        }
                    }
                }
            )) {
                ForEach(properties) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)

            // Operator
            Picker("Op", selection: .init(
                get: { filter.filterOp },
                set: { newOp in updateFilter(at: index) { $0.filterOp = newOp } }
            )) {
                ForEach(DBFilterOp.valid(for: property?.propertyKind ?? .text), id: \.rawValue) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .fixedSize()

            // Value (flavor per kind)
            if filter.filterOp.needsValue, let property {
                filterValueEditor(filter, property: property, at: index)
            }

            Spacer()

            Button {
                var filters = draft.filters ?? []
                filters.remove(at: index)
                draft.filters = filters
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func filterValueEditor(_ filter: DBFilter, property: DBProperty, at index: Int) -> some View {
        switch property.propertyKind {
        case .number:
            TextField("0", text: .init(
                get: { filter.number.map { $0.formatted(.number.grouping(.never)) } ?? "" },
                set: { newText in updateFilter(at: index) { $0.number = Double(newText) } }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
        case .date:
            DatePicker("Date", selection: .init(
                get: {
                    var cell = DBCellValue()
                    cell.date = filter.date
                    return cell.dateValue ?? Date()
                },
                set: { newDate in
                    updateFilter(at: index) { f in
                        var cell = DBCellValue()
                        cell.dateValue = newDate
                        f.date = cell.date
                    }
                }
            ), displayedComponents: [.date])
            .labelsHidden()
        case .select, .multiSelect:
            Picker("Option", selection: .init(
                get: { filter.optionID },
                set: { newID in updateFilter(at: index) { $0.optionID = newID } }
            )) {
                Text("—").tag(Optional<UUID>.none)
                ForEach(store.config(of: property).options ?? []) { option in
                    Text(option.name).tag(Optional(option.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        default:
            TextField("Value", text: .init(
                get: { filter.text ?? "" },
                set: { newText in updateFilter(at: index) { $0.text = newText.isEmpty ? nil : newText } }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)
        }
    }

    private func updateFilter(at index: Int, _ mutate: (inout DBFilter) -> Void) {
        var filters = draft.filters ?? []
        guard index < filters.count else { return }
        mutate(&filters[index])
        draft.filters = filters
    }

    // MARK: Sort row

    private func sortRow(_ sort: DBSort, at index: Int) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Picker("Property", selection: .init(
                get: { sort.propertyID },
                set: { newID in updateSort(at: index) { $0.propertyID = newID } }
            )) {
                ForEach(properties) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)

            Picker("Direction", selection: .init(
                get: { sort.ascending },
                set: { newValue in updateSort(at: index) { $0.ascending = newValue } }
            )) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button {
                var sorts = draft.sorts ?? []
                sorts.remove(at: index)
                draft.sorts = sorts
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func updateSort(at index: Int, _ mutate: (inout DBSort) -> Void) {
        var sorts = draft.sorts ?? []
        guard index < sorts.count else { return }
        mutate(&sorts[index])
        draft.sorts = sorts
    }
}
