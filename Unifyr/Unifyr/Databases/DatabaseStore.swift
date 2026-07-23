//
//  DatabaseStore.swift
//  Unifyr
//
//  The Databases data layer ("Unifyr 1.5"), the sibling of NotesStore: all
//  mutations of DBProperty/DBRow/DBValue go through here, on the view's
//  MainActor ModelContext, so @Query-driven lists stay consistent. Future MCP
//  database tools wrap these same operations.
//
//  A "database" is a Note with `kind == .database` (§4.3). Its columns are
//  DBProperty rows, its records DBRow rows, its cells DBValue rows — all tied
//  together by UUID references (never SwiftData relationships), so partial
//  CloudKit syncs degrade to missing rows, not broken graphs.
//

import Foundation
import SwiftData

@MainActor
struct DatabaseStore {
    let context: ModelContext

    // MARK: - Database lifecycle

    /// Turn a freshly created (empty) note into a database: Notion-style
    /// starter schema — a title property, a Status select, a Date — plus a few
    /// blank rows so the table reads as a table, not a void.
    func seedNewDatabase(_ note: Note) {
        note.kind = .database

        let title = DBProperty(
            databaseNoteID: note.id,
            name: "Name",
            kind: .text,
            configJSON: DBPropertyConfig(isTitle: true).encoded(),
            sortKey: FractionalIndex.keys(count: 3)[0]
        )
        let status = DBProperty(
            databaseNoteID: note.id,
            name: "Status",
            kind: .select,
            configJSON: DBPropertyConfig(options: [
                DBSelectOption(name: "Not started", colorHex: "#7F838C"),
                DBSelectOption(name: "In progress", colorHex: "#F2A65A"),
                DBSelectOption(name: "Done", colorHex: "#3E8EF7"),
            ]).encoded(),
            sortKey: FractionalIndex.keys(count: 3)[1]
        )
        let date = DBProperty(
            databaseNoteID: note.id,
            name: "Date",
            kind: .date,
            sortKey: FractionalIndex.keys(count: 3)[2]
        )
        context.insert(title)
        context.insert(status)
        context.insert(date)

        for key in FractionalIndex.keys(count: 3) {
            context.insert(DBRow(databaseNoteID: note.id, sortKey: key))
        }
    }

    /// Copy a database's payload onto a freshly duplicated note (Phase 5):
    /// properties, rows, cells — new UUIDs throughout — plus saved views with
    /// their property references remapped. Relations and relationTargetIDs
    /// keep pointing at the ORIGINAL targets (a duplicated tracker still
    /// relates to the same other databases). Returns oldRowID → newRowID so
    /// the caller can re-home row-page blocks.
    func duplicateData(from source: Note, to copy: Note) -> [UUID: UUID] {
        var propertyIDMap: [UUID: UUID] = [:]
        for property in fetchProperties(databaseNoteID: source.id) {
            let propertyCopy = DBProperty(
                databaseNoteID: copy.id,
                name: property.name,
                kind: property.propertyKind,
                configJSON: property.configJSON,
                sortKey: property.sortKey
            )
            context.insert(propertyCopy)
            propertyIDMap[property.id] = propertyCopy.id
        }

        var rowIDMap: [UUID: UUID] = [:]
        for row in fetchRows(databaseNoteID: source.id) {
            let rowCopy = DBRow(databaseNoteID: copy.id, sortKey: row.sortKey)
            context.insert(rowCopy)
            rowIDMap[row.id] = rowCopy.id
        }

        for (oldRowID, newRowID) in rowIDMap {
            for (oldPropertyID, newPropertyID) in propertyIDMap {
                let cell = value(rowID: oldRowID, propertyID: oldPropertyID)
                guard !cell.isEmpty else { continue }
                context.insert(DBValue(rowID: newRowID, propertyID: newPropertyID, valueJSON: cell.encoded()))
            }
        }

        // Saved views / board grouping reference property ids — remap them
        // onto the copies or every view filter goes silently inert.
        var settings = settings(of: copy)
        settings.boardGroupPropertyID = settings.boardGroupPropertyID.flatMap { propertyIDMap[$0] }
        settings.views = settings.views.map { views in
            views.map { view in
                var v = view
                v.id = UUID()
                v.groupPropertyID = view.groupPropertyID.flatMap { propertyIDMap[$0] }
                v.filters = view.filters.map { filters in
                    filters.map { filter in
                        var f = filter
                        f.id = UUID()
                        f.propertyID = filter.propertyID.flatMap { propertyIDMap[$0] }
                        return f
                    }
                }
                v.sorts = view.sorts.map { sorts in
                    sorts.map { sort in
                        var s = sort
                        s.id = UUID()
                        s.propertyID = sort.propertyID.flatMap { propertyIDMap[$0] }
                        return s
                    }
                }
                return v
            }
        }
        setSettings(settings, on: copy)
        return rowIDMap
    }

    /// Everything a database owns besides its Note + Blocks (those cascade with
    /// the Note). Called from NotesStore's permanent delete; a no-op for pages.
    func purgeDatabaseData(noteID: UUID) {
        let id: UUID? = noteID
        let rows = fetchRows(databaseNoteID: noteID)
        for row in rows { deleteValues(rowID: row.id) }
        if let properties = try? context.fetch(FetchDescriptor<DBProperty>(
            predicate: #Predicate { $0.databaseNoteID == id }
        )) {
            for property in properties { context.delete(property) }
        }
        for row in rows { context.delete(row) }
    }

    /// All live databases (for relation targets and future pickers).
    func databaseNotes(excluding excludedID: UUID? = nil) -> [Note] {
        let kind = NoteKind.database.rawValue
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.noteKind == kind && $0.deletedAt == nil && !$0.isArchived },
            sortBy: [SortDescriptor(\.title)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.id != excludedID }
    }

    // MARK: - Properties (columns)

    @discardableResult
    func addProperty(
        to note: Note,
        kind: DBPropertyKind,
        name: String? = nil,
        config: DBPropertyConfig = DBPropertyConfig()
    ) -> DBProperty {
        let last = lastSortKey(of: fetchProperties(databaseNoteID: note.id))
        let property = DBProperty(
            databaseNoteID: note.id,
            name: name ?? kind.displayName,
            kind: kind,
            configJSON: config == DBPropertyConfig() ? nil : config.encoded(),
            sortKey: FractionalIndex.keyAfter(last)
        )
        context.insert(property)
        touch(note)
        return property
    }

    func rename(_ property: DBProperty, to name: String, in note: Note) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != property.name else { return }
        property.name = trimmed
        touch(note)
    }

    /// Changing kind keeps every cell's stored fields (DBCellValue is a union),
    /// so switching text → select → text is lossless.
    func changeKind(_ property: DBProperty, to kind: DBPropertyKind, in note: Note) {
        guard property.propertyKind != kind else { return }
        property.propertyKind = kind
        touch(note)
    }

    func deleteProperty(_ property: DBProperty, in note: Note) {
        let propertyID: UUID? = property.id
        if let values = try? context.fetch(FetchDescriptor<DBValue>(
            predicate: #Predicate { $0.propertyID == propertyID }
        )) {
            for value in values { context.delete(value) }
        }
        // If the board grouped by this property, the setting now points at
        // nothing — clear it rather than leaving the board on a ghost.
        var settings = settings(of: note)
        if settings.boardGroupPropertyID == property.id {
            settings.boardGroupPropertyID = nil
            setSettings(settings, on: note)
        }
        context.delete(property)
        touch(note)
    }

    /// Move a column one slot left/right (`offset` -1 / +1) among `ordered`.
    func moveProperty(_ property: DBProperty, offset: Int, within ordered: [DBProperty]) {
        guard let index = ordered.firstIndex(where: { $0.id == property.id }) else { return }
        let target = index + offset
        guard target >= 0, target < ordered.count else { return }
        let lower = target - 1 >= 0 ? ordered[target - 1] : nil
        let upper = ordered[target]
        // Slot between the neighbor pair at the destination (skipping the
        // moving property itself, which still occupies its old slot).
        if offset < 0 {
            property.sortKey = FractionalIndex.keyBetween(lower?.sortKey, upper.sortKey)
        } else {
            let after = target + 1 < ordered.count ? ordered[target + 1] : nil
            property.sortKey = FractionalIndex.keyBetween(upper.sortKey, after?.sortKey)
        }
    }

    // MARK: Property config

    func config(of property: DBProperty) -> DBPropertyConfig {
        DBPropertyConfig.decode(property.configJSON)
    }

    func setConfig(_ config: DBPropertyConfig, on property: DBProperty) {
        let encoded = config.encoded()
        // Guarded: assigning identical bytes still dirties the synced row.
        if property.configJSON != encoded { property.configJSON = encoded }
    }

    /// Create a select option on the property, colored by rotation.
    @discardableResult
    func addOption(named name: String, to property: DBProperty) -> DBSelectOption {
        var config = config(of: property)
        var options = config.options ?? []
        let option = DBSelectOption(
            name: name,
            colorHex: DBOptionPalette.hex(forIndex: options.count)
        )
        options.append(option)
        config.options = options
        setConfig(config, on: property)
        return option
    }

    /// Remove an option and strip it from every cell that referenced it.
    func deleteOption(_ optionID: UUID, from property: DBProperty) {
        var config = config(of: property)
        config.options = (config.options ?? []).filter { $0.id != optionID }
        setConfig(config, on: property)

        let propertyID: UUID? = property.id
        guard let values = try? context.fetch(FetchDescriptor<DBValue>(
            predicate: #Predicate { $0.propertyID == propertyID }
        )) else { return }
        for value in values {
            var cell = DBCellValue.decode(value.valueJSON)
            guard let ids = cell.optionIDs, ids.contains(optionID) else { continue }
            cell.optionIDs = ids.filter { $0 != optionID }
            if cell.isEmpty {
                context.delete(value)
            } else {
                value.valueJSON = cell.encoded()
            }
        }
    }

    // MARK: - Rows

    @discardableResult
    func addRow(to note: Note, setting property: DBProperty? = nil, optionID: UUID? = nil) -> DBRow {
        let last = lastSortKey(of: fetchRows(databaseNoteID: note.id))
        let row = DBRow(databaseNoteID: note.id, sortKey: FractionalIndex.keyAfter(last))
        context.insert(row)
        // Board's "+ New" creates the card already in its column.
        if let property, let optionID {
            var cell = DBCellValue()
            cell.optionIDs = [optionID]
            setValue(cell, rowID: row.id, propertyID: property.id, in: note)
        }
        touch(note)
        return row
    }

    /// Move a row one slot up/down (`offset` -1 / +1) among `ordered`.
    func moveRow(_ row: DBRow, offset: Int, within ordered: [DBRow]) {
        guard let index = ordered.firstIndex(where: { $0.id == row.id }) else { return }
        let target = index + offset
        guard target >= 0, target < ordered.count else { return }
        if offset < 0 {
            let lower = target - 1 >= 0 ? ordered[target - 1] : nil
            row.sortKey = FractionalIndex.keyBetween(lower?.sortKey, ordered[target].sortKey)
        } else {
            let after = target + 1 < ordered.count ? ordered[target + 1] : nil
            row.sortKey = FractionalIndex.keyBetween(ordered[target].sortKey, after?.sortKey)
        }
    }

    /// Delete a row, its cells, and its page blocks. Rows are lightweight
    /// records (unlike notes) so this is a hard delete, behind a confirm in UI.
    func deleteRow(_ row: DBRow, in note: Note) {
        deleteValues(rowID: row.id)
        for block in (note.blocks ?? []) where block.rowID == row.id {
            context.delete(block)
        }
        context.delete(row)
        touch(note)
    }

    // MARK: - Cells

    func value(rowID: UUID, propertyID: UUID) -> DBCellValue {
        fetchValue(rowID: rowID, propertyID: propertyID)
            .map { DBCellValue.decode($0.valueJSON) } ?? DBCellValue()
    }

    /// Upsert one cell. Empty values DELETE the DBValue row — the absence of a
    /// record IS the empty state, which keeps the synced table sparse.
    func setValue(_ cell: DBCellValue, rowID: UUID, propertyID: UUID, in note: Note) {
        let existing = fetchValue(rowID: rowID, propertyID: propertyID)
        if cell.isEmpty {
            if let existing { context.delete(existing) }
        } else if let existing {
            let encoded = cell.encoded()
            guard existing.valueJSON != encoded else { return }
            existing.valueJSON = encoded
        } else {
            context.insert(DBValue(rowID: rowID, propertyID: propertyID, valueJSON: cell.encoded()))
        }
        if let row = fetchRow(id: rowID) { row.modifiedAt = Date() }
        touch(note)
    }

    // MARK: - Titles

    /// The database's title property: the one flagged `isTitle`, else the first
    /// text property, else the first column — always resolvable so every
    /// database has SOME title column even if the flag got lost in a sync.
    func titleProperty(among properties: [DBProperty]) -> DBProperty? {
        properties.first { config(of: $0).isTitle == true }
            ?? properties.first { $0.propertyKind == .text }
            ?? properties.first
    }

    func rowTitle(_ rowID: UUID, titleProperty: DBProperty?) -> String {
        guard let titleProperty else { return "Untitled" }
        let text = value(rowID: rowID, propertyID: titleProperty.id).text ?? ""
        return text.isEmpty ? "Untitled" : text
    }

    /// (id, title) for every row of a database — the relation picker's menu.
    func rowTitles(databaseNoteID: UUID) -> [(id: UUID, title: String)] {
        let properties = fetchProperties(databaseNoteID: databaseNoteID)
        let title = titleProperty(among: properties)
        return fetchRows(databaseNoteID: databaseNoteID).map {
            (id: $0.id, title: rowTitle($0.id, titleProperty: title))
        }
    }

    // MARK: - Display formatting (shared: board cards, embeds)

    /// The human-readable one-line form of a cell, per the property's kind.
    func displayText(_ cell: DBCellValue, property: DBProperty) -> String {
        switch property.propertyKind {
        case .text: cell.text ?? ""
        case .number: cell.number.map { $0.formatted(.number.precision(.fractionLength(0...4)).grouping(.never)) } ?? ""
        case .date: cell.dateValue.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        case .checkbox: (cell.checked ?? false) ? "✓" : ""
        case .url: cell.url ?? ""
        case .person: (cell.people ?? []).joined(separator: ", ")
        case .select, .multiSelect:
            (cell.optionIDs ?? []).compactMap { id in
                (config(of: property).options ?? []).first { $0.id == id }?.name
            }.joined(separator: ", ")
        case .relation:
            (cell.rowIDs ?? []).isEmpty ? "" : "\(cell.rowIDs?.count ?? 0) linked"
        case .rollup: ""
        }
    }

    // MARK: - Saved views (Phase 4)

    /// Filter + sort `rows` per the view. nil view = everything, row order.
    func apply(
        _ view: DBViewConfig?,
        rows: [DBRow],
        values: [UUID: [UUID: DBCellValue]],
        properties: [DBProperty]
    ) -> [DBRow] {
        guard let view else { return rows }
        let byID = Dictionary(uniqueKeysWithValues: properties.map { ($0.id, $0) })

        var result = rows.filter { row in
            (view.filters ?? []).allSatisfy { filter in
                guard let propertyID = filter.propertyID, let property = byID[propertyID] else { return true }
                return matches(filter, cell: values[row.id]?[propertyID] ?? DBCellValue(), property: property)
            }
        }

        for sort in (view.sorts ?? []).reversed() {
            guard let propertyID = sort.propertyID, let property = byID[propertyID] else { continue }
            // Stable per pass, so applying sorts in reverse yields
            // primary-first multi-key ordering.
            result = result.enumerated().sorted { lhs, rhs in
                let l = sortKey(values[lhs.element.id]?[propertyID] ?? DBCellValue(), property: property)
                let r = sortKey(values[rhs.element.id]?[propertyID] ?? DBCellValue(), property: property)
                if l == r { return lhs.offset < rhs.offset }
                return sort.ascending ? l < r : l > r
            }.map(\.element)
        }
        return result
    }

    func matches(_ filter: DBFilter, cell: DBCellValue, property: DBProperty) -> Bool {
        let op = filter.filterOp
        switch op {
        case .isEmpty: return cellIsEmpty(cell, property: property)
        case .isNotEmpty: return !cellIsEmpty(cell, property: property)
        case .checked: return cell.checked ?? false
        case .unchecked: return !(cell.checked ?? false)
        case .hasOption:
            guard let optionID = filter.optionID else { return true }
            return (cell.optionIDs ?? []).contains(optionID)
        case .notHasOption:
            guard let optionID = filter.optionID else { return true }
            return !(cell.optionIDs ?? []).contains(optionID)
        case .contains, .notContains, .equals, .notEquals, .greaterThan, .lessThan:
            switch property.propertyKind {
            case .number:
                guard let target = filter.number else { return true }
                let value = cell.number
                switch op {
                case .equals: return value == target
                case .notEquals: return value != target
                case .greaterThan: return (value ?? -.greatestFiniteMagnitude) > target
                case .lessThan: return (value ?? .greatestFiniteMagnitude) < target
                default: return true
                }
            default:
                let haystack = displayText(cell, property: property)
                let needle = filter.text ?? ""
                guard !needle.isEmpty else { return true }
                switch op {
                case .contains: return haystack.localizedCaseInsensitiveContains(needle)
                case .notContains: return !haystack.localizedCaseInsensitiveContains(needle)
                case .equals: return haystack.localizedCaseInsensitiveCompare(needle) == .orderedSame
                case .notEquals: return haystack.localizedCaseInsensitiveCompare(needle) != .orderedSame
                default: return true
                }
            }
        case .onDate, .beforeDate, .afterDate:
            guard let target = filter.date, !target.isEmpty else { return true }
            guard let value = cell.date, !value.isEmpty else { return false }
            // "yyyy-MM-dd" compares correctly as a string.
            switch op {
            case .onDate: return value == target
            case .beforeDate: return value < target
            case .afterDate: return value > target
            default: return true
            }
        }
    }

    private func cellIsEmpty(_ cell: DBCellValue, property: DBProperty) -> Bool {
        switch property.propertyKind {
        case .relation: (cell.rowIDs ?? []).isEmpty
        case .select, .multiSelect: (cell.optionIDs ?? []).isEmpty
        case .date: (cell.date ?? "").isEmpty
        case .number: cell.number == nil
        case .person: (cell.people ?? []).isEmpty
        case .checkbox: !(cell.checked ?? false)
        default: displayText(cell, property: property).isEmpty
        }
    }

    /// Comparable string per kind (numbers/dates zero-padded ISO-ish so string
    /// order == value order; selects by option position so board order holds).
    private func sortKey(_ cell: DBCellValue, property: DBProperty) -> String {
        switch property.propertyKind {
        case .number:
            guard let number = cell.number else { return "~" } // empties last
            // Offset keeps negatives ordered; 15 digits covers real use.
            return String(format: "%020.4f", number + 1_000_000_000)
        case .date:
            return cell.date ?? "~"
        case .checkbox:
            return (cell.checked ?? false) ? "0" : "1"
        case .select, .multiSelect:
            let options = config(of: property).options ?? []
            guard let first = (cell.optionIDs ?? []).first,
                  let index = options.firstIndex(where: { $0.id == first }) else { return "~" }
            return String(format: "%04d", index)
        default:
            let text = displayText(cell, property: property).lowercased()
            return text.isEmpty ? "~" : text
        }
    }

    // MARK: View CRUD (stored in DatabaseSettings.views)

    func views(of note: Note) -> [DBViewConfig] {
        settings(of: note).views ?? []
    }

    func upsertView(_ view: DBViewConfig, on note: Note) {
        var settings = settings(of: note)
        var views = settings.views ?? []
        if let index = views.firstIndex(where: { $0.id == view.id }) {
            views[index] = view
        } else {
            views.append(view)
        }
        settings.views = views
        setSettings(settings, on: note)
    }

    func deleteView(_ viewID: UUID, on note: Note) {
        var settings = settings(of: note)
        settings.views = (settings.views ?? []).filter { $0.id != viewID }
        if settings.views?.isEmpty == true { settings.views = nil }
        setSettings(settings, on: note)
    }

    // MARK: - Tool value coercion (MCP db_* tools, Phase 6)

    /// Coerce a tool-supplied JSON value onto a property's kind. Forgiving by
    /// design (Claude supplies these): numbers accept strings, checkboxes
    /// accept "yes"/"true", select option NAMES are created when new, and
    /// relations resolve target rows by title or uuid. NSNull / "" yields an
    /// empty cell, which the store treats as "clear".
    func toolCellValue(_ raw: Any, property: DBProperty) -> DBCellValue {
        var cell = DBCellValue()
        if raw is NSNull { return cell }
        let text = ((raw as? String) ?? "").trimmingCharacters(in: .whitespaces)

        func strings() -> [String] {
            if let array = raw as? [Any] {
                return array.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        switch property.propertyKind {
        case .text:
            cell.text = text.isEmpty ? nil : text
        case .url:
            cell.url = text.isEmpty ? nil : text
        case .number:
            cell.number = (raw as? Double)
                ?? (raw as? Int).map(Double.init)
                ?? Double(text.replacingOccurrences(of: ",", with: ""))
        case .checkbox:
            let truthy = (raw as? Bool) ?? ["true", "yes", "1", "checked", "✓"].contains(text.lowercased())
            cell.checked = truthy ? true : nil
        case .date:
            // Accept "yyyy-MM-dd" or a longer ISO string (keep the date part).
            cell.date = text.isEmpty ? nil : String(text.prefix(10))
        case .person:
            let names = strings()
            cell.people = names.isEmpty ? nil : names
        case .select, .multiSelect:
            var ids: [UUID] = []
            for name in strings() {
                let existing = (config(of: property).options ?? [])
                    .first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
                let option = existing ?? addOption(named: name, to: property)
                ids.append(option.id)
            }
            if property.propertyKind == .select { ids = Array(ids.prefix(1)) }
            cell.optionIDs = ids.isEmpty ? nil : ids
        case .relation:
            guard let targetID = config(of: property).relationTargetID else { break }
            let targets = rowTitles(databaseNoteID: targetID)
            var ids: [UUID] = []
            for ref in strings() {
                if let id = UUID(uuidString: ref), targets.contains(where: { $0.id == id }) {
                    ids.append(id)
                } else if let match = targets.first(where: {
                    $0.title.localizedCaseInsensitiveCompare(ref) == .orderedSame
                }) {
                    ids.append(match.id)
                }
            }
            cell.rowIDs = ids.isEmpty ? nil : ids
        case .rollup:
            break
        }
        return cell
    }

    /// A row by id, with its owning database note — the db_update/delete tools
    /// identify rows this way.
    func rowWithDatabase(id: UUID) -> (row: DBRow, note: Note)? {
        let rowID = id
        var descriptor = FetchDescriptor<DBRow>(predicate: #Predicate { $0.id == rowID })
        descriptor.fetchLimit = 1
        guard let row = ((try? context.fetch(descriptor)) ?? []).first,
              let databaseID = row.databaseNoteID else { return nil }
        var noteDescriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == databaseID })
        noteDescriptor.fetchLimit = 1
        guard let note = ((try? context.fetch(noteDescriptor)) ?? []).first, !note.isTrashed else { return nil }
        return (row, note)
    }

    // MARK: - Embed snapshots (dbembed blocks, Phase 4)

    /// The read-only preview payload a `dbembed` editor block renders:
    /// {title, view, columns, rows (display strings), more}. nil if the
    /// database is gone/trashed.
    func embedSnapshotJSON(databaseID: UUID, viewID: UUID?, rowLimit: Int = 8) -> String? {
        let kind = NoteKind.database.rawValue
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == databaseID && $0.noteKind == kind && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1
        guard let note = ((try? context.fetch(descriptor)) ?? []).first else { return nil }

        let properties = fetchProperties(databaseNoteID: databaseID)
        let rows = fetchRows(databaseNoteID: databaseID)
        var values: [UUID: [UUID: DBCellValue]] = [:]
        for row in rows {
            for property in properties {
                let cell = value(rowID: row.id, propertyID: property.id)
                if !cell.isEmpty { values[row.id, default: [:]][property.id] = cell }
            }
        }
        let view = viewID.flatMap { id in views(of: note).first { $0.id == id } }
        let visible = apply(view, rows: rows, values: values, properties: properties)

        // First 4 columns keep the preview readable; the full table is a click
        // away.
        let columns = Array(properties.prefix(4))
        let payload: [String: Any] = [
            "title": note.title.isEmpty ? "Untitled" : note.title,
            "emoji": note.emoji ?? "📊",
            "view": view?.name ?? "",
            "columns": columns.map(\.name),
            "rows": visible.prefix(rowLimit).map { row in
                columns.map { displayText(values[row.id]?[$0.id] ?? DBCellValue(), property: $0) }
            },
            "more": max(0, visible.count - rowLimit),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Database settings (Note.schemaJSON)

    func settings(of note: Note) -> DatabaseSettings {
        DatabaseSettings.decode(note.schemaJSON)
    }

    func setSettings(_ settings: DatabaseSettings, on note: Note) {
        let encoded = settings.encoded()
        if note.schemaJSON != encoded { note.schemaJSON = encoded }
    }

    // MARK: - Row pages (blocks scoped by rowID)
    //
    // A row's page content is the note's Blocks carrying `rowID == row.id`
    // (§4.3) — they live on the database note so the Note→Block cascade still
    // owns them. Load/save mirror NotesStore.save exactly, scoped to the row.

    func loadRowDocument(_ row: DBRow, in note: Note) -> PMNode {
        let blocks = (note.blocks ?? [])
            .filter { $0.rowID == row.id }
            .sorted { $0.sortKey < $1.sortKey }
        // Same live-label refresh as note pages (mentions work in row pages).
        return BlockSerializer.refreshingPageRefs(
            BlockSerializer.document(from: blocks),
            resolve: NotesStore(context: context).pageRefResolver()
        )
    }

    func saveRowDocument(_ document: PMNode, row: DBRow, in note: Note) {
        let contents = BlockSerializer.blocks(from: document)
        let existing = (note.blocks ?? [])
            .filter { $0.rowID == row.id }
            .sorted { $0.sortKey < $1.sortKey }
        let keys = FractionalIndex.keys(count: contents.count)

        for (index, content) in contents.enumerated() {
            let block: Block
            if index < existing.count {
                block = existing[index]
            } else {
                block = Block(note: note)
                block.rowID = row.id
                context.insert(block)
            }
            BlockSerializer.apply(content, to: block)
            if block.sortKey != keys[index] { block.sortKey = keys[index] }
        }
        if existing.count > contents.count {
            for stale in existing[contents.count...] {
                context.delete(stale)
            }
        }
        row.modifiedAt = Date()
        touch(note)
    }

    // MARK: - Private fetches

    private func touch(_ note: Note) {
        note.modifiedAt = Date()
    }

    private func lastSortKey(of properties: [DBProperty]) -> String? {
        properties.last?.sortKey
    }

    private func lastSortKey(of rows: [DBRow]) -> String? {
        rows.last?.sortKey
    }

    func fetchProperties(databaseNoteID: UUID) -> [DBProperty] {
        let id: UUID? = databaseNoteID
        let descriptor = FetchDescriptor<DBProperty>(
            predicate: #Predicate { $0.databaseNoteID == id },
            sortBy: [SortDescriptor(\.sortKey)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchRows(databaseNoteID: UUID) -> [DBRow] {
        let id: UUID? = databaseNoteID
        let descriptor = FetchDescriptor<DBRow>(
            predicate: #Predicate { $0.databaseNoteID == id },
            sortBy: [SortDescriptor(\.sortKey)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchRow(id: UUID) -> DBRow? {
        let rowID = id
        var descriptor = FetchDescriptor<DBRow>(predicate: #Predicate { $0.id == rowID })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).first
    }

    private func fetchValue(rowID: UUID, propertyID: UUID) -> DBValue? {
        let row: UUID? = rowID
        let property: UUID? = propertyID
        var descriptor = FetchDescriptor<DBValue>(
            predicate: #Predicate { $0.rowID == row && $0.propertyID == property }
        )
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).first
    }

    private func deleteValues(rowID: UUID) {
        let id: UUID? = rowID
        guard let values = try? context.fetch(FetchDescriptor<DBValue>(
            predicate: #Predicate { $0.rowID == id }
        )) else { return }
        for value in values { context.delete(value) }
    }
}
