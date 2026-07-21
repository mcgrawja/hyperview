//
//  DatabaseCells.swift
//  Unifyr
//
//  Per-kind cell editors, shared by the table view and the row page. A cell is
//  dumb: it receives the current DBCellValue and reports a whole replacement
//  value through `commit` — DatabaseStore decides how to persist it.
//

import SwiftUI
import SwiftData

// MARK: - Kind dispatch

/// One editable cell for `property` on one row.
struct DatabaseCellEditor: View {
    let property: DBProperty
    let config: DBPropertyConfig
    let value: DBCellValue
    /// The database note (relation popovers fetch target rows through it).
    let note: Note
    let commit: (DBCellValue) -> Void

    var body: some View {
        switch property.propertyKind {
        case .text:
            CommittingTextField(value: value.text ?? "", placeholder: "") { text in
                var cell = value
                cell.text = text.isEmpty ? nil : text
                commit(cell)
            }
        case .number:
            CommittingTextField(
                value: value.number.map(Self.numberText) ?? "",
                placeholder: "",
                alignment: .trailing
            ) { text in
                var cell = value
                cell.number = Double(text.replacingOccurrences(of: ",", with: ""))
                commit(cell)
            }
        case .checkbox:
            CheckboxCell(value: value, commit: commit)
        case .date:
            DateCell(value: value, commit: commit)
        case .select:
            SelectCell(property: property, config: config, value: value, allowsMultiple: false, commit: commit)
        case .multiSelect:
            SelectCell(property: property, config: config, value: value, allowsMultiple: true, commit: commit)
        case .url:
            URLCell(value: value, commit: commit)
        case .person:
            CommittingTextField(value: (value.people ?? []).joined(separator: ", "), placeholder: "") { text in
                var cell = value
                let people = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                cell.people = people.isEmpty ? nil : people
                commit(cell)
            }
        case .relation:
            RelationCell(config: config, value: value, commit: commit)
        case .rollup:
            Text("—").foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// "3" not "3.0"; up to 4 fraction digits otherwise.
    static func numberText(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
    }
}

// MARK: - Text plumbing

/// A TextField that syncs FROM the store when unfocused and commits TO it
/// debounced while typing (per-keystroke saves would storm CloudKit), plus on
/// submit and focus loss so nothing is lost.
struct CommittingTextField: View {
    let value: String
    var placeholder = ""
    var alignment: TextAlignment = .leading
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in
                if !focused { text = new }
            }
            .onChange(of: text) { _, new in
                guard new != value else { return }
                debounce?.cancel()
                debounce = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    commit(new)
                }
            }
            .onSubmit { flush() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { flush() }
            }
            .onDisappear { flush() }
    }

    private func flush() {
        debounce?.cancel()
        if text != value { commit(text) }
    }
}

// MARK: - Checkbox

private struct CheckboxCell: View {
    let value: DBCellValue
    let commit: (DBCellValue) -> Void

    var body: some View {
        Button {
            var cell = value
            cell.checked = (value.checked ?? false) ? nil : true
            commit(cell)
        } label: {
            Image(systemName: (value.checked ?? false) ? "checkmark.square.fill" : "square")
                .foregroundStyle(
                    (value.checked ?? false) ? Theme.Palette.primary : Theme.Palette.textSecondary
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Date

private struct DateCell: View {
    let value: DBCellValue
    let commit: (DBCellValue) -> Void

    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            Text(value.dateValue.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPicker) {
            VStack(spacing: Theme.Spacing.sm) {
                DatePicker(
                    "Date",
                    selection: Binding(
                        get: { value.dateValue ?? Date() },
                        set: { newDate in
                            var cell = value
                            cell.dateValue = newDate
                            commit(cell)
                        }
                    ),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()

                if value.dateValue != nil {
                    Button("Clear Date") {
                        var cell = value
                        cell.dateValue = nil
                        commit(cell)
                        showingPicker = false
                    }
                    .foregroundStyle(Theme.Palette.danger)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(width: 300)
        }
    }
}

// MARK: - Select / Multi-select

private struct SelectCell: View {
    let property: DBProperty
    let config: DBPropertyConfig
    let value: DBCellValue
    let allowsMultiple: Bool
    let commit: (DBCellValue) -> Void

    @Environment(\.modelContext) private var context
    @State private var showingPicker = false
    @State private var newOptionName = ""

    private var options: [DBSelectOption] { config.options ?? [] }
    private var selectedIDs: [UUID] { value.optionIDs ?? [] }
    private var selected: [DBSelectOption] {
        selectedIDs.compactMap { id in options.first { $0.id == id } }
    }

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                if selected.isEmpty {
                    Text("")
                } else {
                    ForEach(selected) { option in
                        OptionChip(option: option)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPicker) {
            picker
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Create-inline, Notion-style: type a name, hit return.
            TextField("Add an option…", text: $newOptionName)
                .textFieldStyle(.plain)
                .padding(Theme.Spacing.md)
                .onSubmit(createOption)

            Divider().overlay(Theme.Palette.separator)

            if options.isEmpty {
                Text("No options yet.")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(Theme.Spacing.md)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        ForEach(options) { option in
                            optionRow(option)
                        }
                    }
                    .padding(Theme.Spacing.sm)
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 240)
    }

    private func optionRow(_ option: DBSelectOption) -> some View {
        Button {
            toggle(option)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                OptionChip(option: option)
                Spacer()
                if selectedIDs.contains(option.id) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.primary)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .padding(.horizontal, Theme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Option", role: .destructive) {
                DatabaseStore(context: context).deleteOption(option.id, from: property)
                try? context.save()
            }
        }
    }

    private func toggle(_ option: DBSelectOption) {
        var cell = value
        if allowsMultiple {
            var ids = selectedIDs
            if let index = ids.firstIndex(of: option.id) {
                ids.remove(at: index)
            } else {
                ids.append(option.id)
            }
            cell.optionIDs = ids.isEmpty ? nil : ids
        } else {
            cell.optionIDs = selectedIDs == [option.id] ? nil : [option.id]
            showingPicker = false
        }
        commit(cell)
    }

    private func createOption() {
        let name = newOptionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newOptionName = ""
        let store = DatabaseStore(context: context)
        // Reuse an existing option of the same name instead of duplicating.
        let option = options.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? store.addOption(named: name, to: property)
        try? context.save()
        toggle(option)
    }
}

/// The colored capsule a select value renders as, everywhere.
struct OptionChip: View {
    let option: DBSelectOption

    var body: some View {
        Text(option.name)
            .font(Theme.Font.cardCaption)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                (Color(hexString: option.colorHex) ?? Theme.Palette.primary).softFill(0.20),
                in: Capsule()
            )
    }
}

// MARK: - URL

private struct URLCell: View {
    let value: DBCellValue
    let commit: (DBCellValue) -> Void

    private var url: URL? {
        guard var string = value.url, !string.isEmpty else { return nil }
        if !string.contains("://") { string = "https://\(string)" }
        return URL(string: string)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            CommittingTextField(value: value.url ?? "", placeholder: "") { text in
                var cell = value
                cell.url = text.isEmpty ? nil : text
                commit(cell)
            }
            if let url {
                Button {
                    PlatformKit.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(Theme.Palette.primary)
                }
                .buttonStyle(.plain)
                .help("Open link")
            }
        }
    }
}

// MARK: - Relation

private struct RelationCell: View {
    let config: DBPropertyConfig
    let value: DBCellValue
    let commit: (DBCellValue) -> Void

    @Environment(\.modelContext) private var context
    @State private var showingPicker = false

    private var linkedIDs: [UUID] { value.rowIDs ?? [] }

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            Text(linkedTitles().joined(separator: ", "))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPicker) {
            RelationPicker(
                targetDatabaseID: config.relationTargetID,
                linkedIDs: linkedIDs
            ) { ids in
                var cell = value
                cell.rowIDs = ids.isEmpty ? nil : ids
                commit(cell)
            }
        }
    }

    private func linkedTitles() -> [String] {
        guard let targetID = config.relationTargetID, !linkedIDs.isEmpty else { return [] }
        let titles = Dictionary(
            uniqueKeysWithValues: DatabaseStore(context: context)
                .rowTitles(databaseNoteID: targetID)
                .map { ($0.id, $0.title) }
        )
        // A target row deleted on another device simply stops resolving.
        return linkedIDs.compactMap { titles[$0] }
    }
}

/// Searchable multi-toggle over the target database's rows.
private struct RelationPicker: View {
    let targetDatabaseID: UUID?
    let linkedIDs: [UUID]
    let commit: ([UUID]) -> Void

    @Environment(\.modelContext) private var context
    @State private var query = ""

    private var targetRows: [(id: UUID, title: String)] {
        guard let targetDatabaseID else { return [] }
        let rows = DatabaseStore(context: context).rowTitles(databaseNoteID: targetDatabaseID)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("Search rows…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(Theme.Spacing.md)

            Divider().overlay(Theme.Palette.separator)

            if targetDatabaseID == nil {
                Text("This relation has no target database.")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(Theme.Spacing.md)
            } else if targetRows.isEmpty {
                Text("No rows.")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(Theme.Spacing.md)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        ForEach(targetRows, id: \.id) { row in
                            Button {
                                toggle(row.id)
                            } label: {
                                HStack {
                                    Text(row.title).lineLimit(1)
                                    Spacer()
                                    if linkedIDs.contains(row.id) {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(Theme.Palette.primary)
                                    }
                                }
                                .padding(.vertical, Theme.Spacing.xs)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Theme.Spacing.sm)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 280)
    }

    private func toggle(_ id: UUID) {
        var ids = linkedIDs
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        commit(ids)
    }
}
