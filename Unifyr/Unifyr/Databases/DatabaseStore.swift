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
        return BlockSerializer.document(from: blocks)
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
