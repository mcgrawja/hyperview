//
//  DatabaseStoreTests.swift
//  UnifyrTests
//
//  "Unifyr 1.5: Databases" — store behavior over an in-memory container: the
//  seeded schema, cell upsert/empty-delete semantics, option lifecycle,
//  relation values, row-page block scoping, and the full purge that permanent
//  note deletion relies on.
//

import Testing
import Foundation
import SwiftData
@testable import Unifyr

@MainActor
struct DatabaseStoreTests {

    /// A fresh, isolated in-memory stack per test.
    private func makeContext() -> ModelContext {
        let configuration = ModelConfiguration(
            schema: UnifyrSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try! ModelContainer(for: UnifyrSchema.schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeDatabase(_ context: ModelContext) -> (DatabaseStore, Note) {
        let store = DatabaseStore(context: context)
        let note = NotesStore(context: context).createNote(title: "Tracker")
        store.seedNewDatabase(note)
        return (store, note)
    }

    // MARK: Seeding

    @Test func seedCreatesStarterSchema() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)

        #expect(note.kind == .database)
        let properties = store.fetchProperties(databaseNoteID: note.id)
        #expect(properties.map(\.name) == ["Name", "Status", "Date"])
        #expect(properties.map(\.propertyKind) == [.text, .select, .date])
        #expect(store.fetchRows(databaseNoteID: note.id).count == 3)

        // The seeded title property is discoverable via the isTitle flag.
        let title = store.titleProperty(among: properties)
        #expect(title?.name == "Name")
        #expect(store.config(of: title!).isTitle == true)

        // The Status select carries its three starter options.
        let status = properties[1]
        #expect((store.config(of: status).options ?? []).map(\.name) == ["Not started", "In progress", "Done"])
    }

    // MARK: Cell values

    @Test func setValueUpsertsAndEmptyDeletes() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)
        let properties = store.fetchProperties(databaseNoteID: note.id)
        let row = store.fetchRows(databaseNoteID: note.id)[0]
        let name = properties[0]

        var cell = DBCellValue()
        cell.text = "Ship the databases module"
        store.setValue(cell, rowID: row.id, propertyID: name.id, in: note)
        #expect(store.value(rowID: row.id, propertyID: name.id).text == "Ship the databases module")
        #expect(try! context.fetchCount(FetchDescriptor<DBValue>()) == 1)

        // Overwrite in place — still one DBValue.
        cell.text = "Shipped"
        store.setValue(cell, rowID: row.id, propertyID: name.id, in: note)
        #expect(store.value(rowID: row.id, propertyID: name.id).text == "Shipped")
        #expect(try! context.fetchCount(FetchDescriptor<DBValue>()) == 1)

        // Clearing to empty DELETES the record — absence is the empty state.
        cell.text = nil
        store.setValue(cell, rowID: row.id, propertyID: name.id, in: note)
        #expect(try! context.fetchCount(FetchDescriptor<DBValue>()) == 0)
    }

    @Test func cellValueRoundTripsEveryField() {
        var cell = DBCellValue()
        cell.text = "t"
        cell.number = 4.25
        cell.optionIDs = [UUID()]
        cell.dateValue = DBCellValue().dateValue // nil round-trip guard
        cell.date = "2026-07-21"
        cell.checked = true
        cell.url = "https://example.com"
        cell.people = ["Jason"]
        cell.rowIDs = [UUID(), UUID()]

        let decoded = DBCellValue.decode(cell.encoded())
        #expect(decoded == cell)
        #expect(decoded.dateValue != nil)
        #expect(decoded.isEmpty == false)
        #expect(DBCellValue().isEmpty)
        // Encoding is byte-stable (sorted keys) so saves can be no-op guarded.
        #expect(cell.encoded() == decoded.encoded())
    }

    // MARK: Options

    @Test func optionLifecycle() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)
        let status = store.fetchProperties(databaseNoteID: note.id)[1]
        let row = store.fetchRows(databaseNoteID: note.id)[0]

        let option = store.addOption(named: "Blocked", to: status)
        #expect((store.config(of: status).options ?? []).count == 4)

        var cell = DBCellValue()
        cell.optionIDs = [option.id]
        store.setValue(cell, rowID: row.id, propertyID: status.id, in: note)

        // Deleting the option strips it from config AND from cells; the cell
        // becomes empty and its record is dropped.
        store.deleteOption(option.id, from: status)
        #expect((store.config(of: status).options ?? []).count == 3)
        #expect(store.value(rowID: row.id, propertyID: status.id).optionIDs == nil)
    }

    // MARK: Properties

    @Test func addMoveDeleteProperty() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)

        let url = store.addProperty(to: note, kind: .url, name: "Link")
        var names = store.fetchProperties(databaseNoteID: note.id).map(\.name)
        #expect(names == ["Name", "Status", "Date", "Link"])

        store.moveProperty(url, offset: -1, within: store.fetchProperties(databaseNoteID: note.id))
        names = store.fetchProperties(databaseNoteID: note.id).map(\.name)
        #expect(names == ["Name", "Status", "Link", "Date"])

        // Deleting a property drops its values too.
        let row = store.fetchRows(databaseNoteID: note.id)[0]
        var cell = DBCellValue()
        cell.url = "https://unifyr.app"
        store.setValue(cell, rowID: row.id, propertyID: url.id, in: note)
        store.deleteProperty(url, in: note)
        #expect(store.fetchProperties(databaseNoteID: note.id).count == 3)
        #expect(try! context.fetchCount(FetchDescriptor<DBValue>()) == 0)
    }

    // MARK: Rows and titles

    @Test func rowTitlesResolveThroughTitleProperty() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)
        let name = store.fetchProperties(databaseNoteID: note.id)[0]
        let rows = store.fetchRows(databaseNoteID: note.id)

        var cell = DBCellValue()
        cell.text = "First"
        store.setValue(cell, rowID: rows[0].id, propertyID: name.id, in: note)

        let titles = store.rowTitles(databaseNoteID: note.id).map(\.title)
        #expect(titles == ["First", "Untitled", "Untitled"])
    }

    @Test func boardAddRowLandsInColumn() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)
        let status = store.fetchProperties(databaseNoteID: note.id)[1]
        let option = (store.config(of: status).options ?? [])[1]

        let row = store.addRow(to: note, setting: status, optionID: option.id)
        #expect(store.value(rowID: row.id, propertyID: status.id).optionIDs == [option.id])
    }

    // MARK: Row pages

    @Test func rowDocumentsAreScopedPerRow() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)
        let rows = store.fetchRows(databaseNoteID: note.id)

        let document = PMNode(
            type: "doc",
            content: [PMNode(type: "paragraph", content: [.text("row zero body")])]
        )
        store.saveRowDocument(document, row: rows[0], in: note)
        // The UI saves after every mutation; do the same so the note.blocks
        // relationship reflects the pending inserts before it's read.
        try? context.save()

        // Round-trips for its own row…
        let back = store.loadRowDocument(rows[0], in: note)
        #expect(back == document)
        // …and never leaks into a sibling row's page.
        let sibling = store.loadRowDocument(rows[1], in: note)
        #expect((sibling.content ?? []).isEmpty)

        // Deleting the row deletes its page blocks.
        store.deleteRow(rows[0], in: note)
        try? context.save()
        let remaining = (try? context.fetch(FetchDescriptor<Block>())) ?? []
        #expect(remaining.filter { $0.rowID != nil }.isEmpty)
    }

    // MARK: Saved views (Phase 4)

    /// Name + Status + Date seeded database with three populated rows.
    private func makePopulated(_ context: ModelContext) -> (DatabaseStore, Note, name: DBProperty, status: DBProperty, date: DBProperty) {
        let (store, note) = makeDatabase(context)
        let properties = store.fetchProperties(databaseNoteID: note.id)
        let (name, status, date) = (properties[0], properties[1], properties[2])
        let options = store.config(of: status).options ?? []
        let rows = store.fetchRows(databaseNoteID: note.id)
        let seed: [(String, Int, String)] = [("Bravo", 0, "2026-07-30"), ("Alpha", 1, "2026-07-01"), ("Charlie", 2, "2026-08-15")]
        for (index, row) in rows.enumerated() {
            var cell = DBCellValue()
            cell.text = seed[index].0
            store.setValue(cell, rowID: row.id, propertyID: name.id, in: note)
            var statusCell = DBCellValue()
            statusCell.optionIDs = [options[seed[index].1].id]
            store.setValue(statusCell, rowID: row.id, propertyID: status.id, in: note)
            var dateCell = DBCellValue()
            dateCell.date = seed[index].2
            store.setValue(dateCell, rowID: row.id, propertyID: date.id, in: note)
        }
        try? context.save()
        return (store, note, name, status, date)
    }

    private func values(_ store: DatabaseStore, _ note: Note) -> [UUID: [UUID: DBCellValue]] {
        let properties = store.fetchProperties(databaseNoteID: note.id)
        var result: [UUID: [UUID: DBCellValue]] = [:]
        for row in store.fetchRows(databaseNoteID: note.id) {
            for property in properties {
                let cell = store.value(rowID: row.id, propertyID: property.id)
                if !cell.isEmpty { result[row.id, default: [:]][property.id] = cell }
            }
        }
        return result
    }

    @Test func viewFiltersAndSorts() {
        let context = makeContext()
        let (store, note, name, status, date) = makePopulated(context)
        let properties = store.fetchProperties(databaseNoteID: note.id)
        let rows = store.fetchRows(databaseNoteID: note.id)
        let vals = values(store, note)
        let inProgress = (store.config(of: status).options ?? [])[1]

        // Filter: Status is "In progress" → only Alpha.
        var view = DBViewConfig()
        var filter = DBFilter()
        filter.propertyID = status.id
        filter.filterOp = .hasOption
        filter.optionID = inProgress.id
        view.filters = [filter]
        var out = store.apply(view, rows: rows, values: vals, properties: properties)
        #expect(out.map { store.rowTitle($0.id, titleProperty: name) } == ["Alpha"])

        // Sort: by name ascending.
        view.filters = nil
        var sort = DBSort()
        sort.propertyID = name.id
        view.sorts = [sort]
        out = store.apply(view, rows: rows, values: vals, properties: properties)
        #expect(out.map { store.rowTitle($0.id, titleProperty: name) } == ["Alpha", "Bravo", "Charlie"])

        // Sort: by date descending.
        sort.propertyID = date.id
        sort.ascending = false
        view.sorts = [sort]
        out = store.apply(view, rows: rows, values: vals, properties: properties)
        #expect(out.map { store.rowTitle($0.id, titleProperty: name) } == ["Charlie", "Bravo", "Alpha"])

        // Date filter: before 2026-08-01.
        var dateFilter = DBFilter()
        dateFilter.propertyID = date.id
        dateFilter.filterOp = .beforeDate
        dateFilter.date = "2026-08-01"
        view.filters = [dateFilter]
        out = store.apply(view, rows: rows, values: vals, properties: properties)
        #expect(Set(out.map { store.rowTitle($0.id, titleProperty: name) }) == ["Alpha", "Bravo"])
    }

    @Test func viewCRUDPersistsInSettings() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)

        var view = DBViewConfig()
        view.name = "Open items"
        store.upsertView(view, on: note)
        #expect(store.views(of: note).map(\.name) == ["Open items"])

        view.name = "Renamed"
        store.upsertView(view, on: note)
        #expect(store.views(of: note).map(\.name) == ["Renamed"])

        // Round-trips through the schemaJSON bytes.
        let decoded = DatabaseSettings.decode(note.schemaJSON)
        #expect(decoded.views?.first?.name == "Renamed")

        store.deleteView(view.id, on: note)
        #expect(store.views(of: note).isEmpty)
    }

    @Test func embedSnapshotRespectsViewAndLimit() throws {
        let context = makeContext()
        let (store, note, _, status, _) = makePopulated(context)
        let inProgress = (store.config(of: status).options ?? [])[1]

        var view = DBViewConfig()
        view.name = "Active"
        var filter = DBFilter()
        filter.propertyID = status.id
        filter.filterOp = .hasOption
        filter.optionID = inProgress.id
        view.filters = [filter]
        store.upsertView(view, on: note)
        try context.save()

        let json = try #require(store.embedSnapshotJSON(databaseID: note.id, viewID: view.id))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(payload["title"] as? String == "Tracker")
        #expect(payload["view"] as? String == "Active")
        #expect((payload["rows"] as? [[String]])?.count == 1)
        #expect((payload["rows"] as? [[String]])?.first?.first == "Alpha")
        #expect(payload["more"] as? Int == 0)

        // Unknown database → nil (deleted on another device).
        #expect(store.embedSnapshotJSON(databaseID: UUID(), viewID: nil) == nil)
    }

    // MARK: Tool value coercion (Phase 6 MCP)

    @Test func toolCellValueCoercesEveryKind() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)
        let properties = store.fetchProperties(databaseNoteID: note.id)
        let (name, status, date) = (properties[0], properties[1], properties[2])

        // Text.
        #expect(store.toolCellValue("Fix roof", property: name).text == "Fix roof")
        // Clearing forms.
        #expect(store.toolCellValue("", property: name).isEmpty)
        #expect(store.toolCellValue(NSNull(), property: name).isEmpty)

        // Select by option NAME (existing, case-insensitive).
        let done = store.toolCellValue("done", property: status)
        let doneOption = (store.config(of: status).options ?? []).first { $0.name == "Done" }
        #expect(done.optionIDs == [doneOption!.id])
        // Unknown option names are created on the fly.
        let before = (store.config(of: status).options ?? []).count
        let blocked = store.toolCellValue("Blocked", property: status)
        #expect((store.config(of: status).options ?? []).count == before + 1)
        #expect(blocked.optionIDs?.count == 1)

        // Dates keep the date part of longer ISO strings.
        #expect(store.toolCellValue("2026-08-01T09:00:00Z", property: date).date == "2026-08-01")

        // Numbers accept strings; checkboxes accept "yes".
        let number = store.addProperty(to: note, kind: .number, name: "Cost")
        #expect(store.toolCellValue("1,250", property: number).number == 1250)
        #expect(store.toolCellValue(42.5, property: number).number == 42.5)
        let flag = store.addProperty(to: note, kind: .checkbox, name: "Paid")
        #expect(store.toolCellValue("yes", property: flag).checked == true)
        #expect(store.toolCellValue(false, property: flag).isEmpty)
    }

    @Test func toolCellValueResolvesRelationsByTitle() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)
        // A second database to relate to, with one titled row.
        let target = NotesStore(context: context).createPage(title: "People")
        store.seedNewDatabase(target)
        let targetName = store.fetchProperties(databaseNoteID: target.id)[0]
        let targetRow = store.fetchRows(databaseNoteID: target.id)[0]
        var cell = DBCellValue()
        cell.text = "Jason"
        store.setValue(cell, rowID: targetRow.id, propertyID: targetName.id, in: target)

        let relation = store.addProperty(
            to: note,
            kind: .relation,
            name: "Owner",
            config: DBPropertyConfig(relationTargetID: target.id)
        )
        try? context.save()

        // By title, by uuid, and unresolvable.
        #expect(store.toolCellValue("jason", property: relation).rowIDs == [targetRow.id])
        #expect(store.toolCellValue(targetRow.id.uuidString, property: relation).rowIDs == [targetRow.id])
        #expect(store.toolCellValue("Nobody", property: relation).isEmpty)
    }

    @Test func rowWithDatabaseResolvesOwner() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)
        let row = store.fetchRows(databaseNoteID: note.id)[0]
        try? context.save()

        let resolved = store.rowWithDatabase(id: row.id)
        #expect(resolved?.row.id == row.id)
        #expect(resolved?.note.id == note.id)
        #expect(store.rowWithDatabase(id: UUID()) == nil)
    }

    // MARK: Purge

    @Test func purgeRemovesEverythingTheNoteOwns() {
        let context = makeContext()
        let (store, note) = makeDatabase(context)
        let name = store.fetchProperties(databaseNoteID: note.id)[0]
        let row = store.fetchRows(databaseNoteID: note.id)[0]
        var cell = DBCellValue()
        cell.text = "value"
        store.setValue(cell, rowID: row.id, propertyID: name.id, in: note)

        // The path permanent deletion takes (NotesStore.purgeExternalReferences).
        store.purgeDatabaseData(noteID: note.id)
        #expect(try! context.fetchCount(FetchDescriptor<DBProperty>()) == 0)
        #expect(try! context.fetchCount(FetchDescriptor<DBRow>()) == 0)
        #expect(try! context.fetchCount(FetchDescriptor<DBValue>()) == 0)
    }
}
