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
