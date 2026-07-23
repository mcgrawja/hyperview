//
//  PageTreeTests.swift
//  UnifyrTests
//
//  Notion-style page tree (2026-07-22 refocus): subtree trash/restore, move
//  validation (no cycles), and permanent-delete purging down the subtree.
//

import Testing
import Foundation
import SwiftData
@testable import Unifyr

@MainActor
struct PageTreeTests {

    private func makeContext() -> ModelContext {
        let configuration = ModelConfiguration(
            schema: UnifyrSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try! ModelContainer(for: UnifyrSchema.schema, configurations: [configuration])
        return ModelContext(container)
    }

    /// root ─ child ─ grandchild, plus an unrelated sibling of root.
    private func makeTree(_ context: ModelContext) -> (NotesStore, root: Note, child: Note, grandchild: Note, other: Note) {
        let store = NotesStore(context: context)
        let root = store.createPage(title: "Root")
        let child = store.createPage(title: "Child", parent: root)
        let grandchild = store.createPage(title: "Grandchild", parent: child)
        let other = store.createPage(title: "Other")
        try? context.save()
        return (store, root, child, grandchild, other)
    }

    private func allNotes(_ context: ModelContext) -> [Note] {
        (try? context.fetch(FetchDescriptor<Note>())) ?? []
    }

    @Test func createNestsAndOrders() {
        let context = makeContext()
        let (store, root, child, _, _) = makeTree(context)

        #expect(child.parentNoteID == root.id)
        let second = store.createPage(title: "Second", parent: root)
        try? context.save()
        // Siblings order by sortKey: Child then Second.
        let siblings = allNotes(context)
            .filter { $0.parentNoteID == root.id }
            .sorted { $0.sortKey < $1.sortKey }
        #expect(siblings.map(\.title) == ["Child", "Second"])
        _ = second
    }

    @Test func descendantsWalksTheWholeSubtree() {
        let context = makeContext()
        let (store, root, child, grandchild, other) = makeTree(context)

        let names = Set(store.descendants(of: root, in: allNotes(context)).map(\.title))
        #expect(names == ["Child", "Grandchild"])
        #expect(store.descendants(of: other, in: allNotes(context)).isEmpty)
        _ = (child, grandchild)
    }

    @Test func deleteTrashesSubtreeAndRestoreBringsItBack() {
        let context = makeContext()
        let (store, root, child, grandchild, other) = makeTree(context)

        store.delete(root, in: allNotes(context))
        try? context.save()
        #expect(root.isTrashed && child.isTrashed && grandchild.isTrashed)
        #expect(!other.isTrashed)
        // Children keep their parent links while trashed…
        #expect(child.parentNoteID == root.id)

        // …so restore is just clearing deletedAt down the subtree.
        store.restore(root, in: allNotes(context))
        try? context.save()
        #expect(!root.isTrashed && !child.isTrashed && !grandchild.isTrashed)
        #expect(child.parentNoteID == root.id)
    }

    @Test func restoreWithTrashedParentLandsAtTopLevel() {
        let context = makeContext()
        let (store, root, child, _, _) = makeTree(context)

        // Trash the whole tree, then restore ONLY the child.
        store.delete(root, in: allNotes(context))
        store.restore(child, in: allNotes(context))
        try? context.save()

        // Its parent is still in the trash, so it surfaces at the top level.
        #expect(child.parentNoteID == nil)
        #expect(!child.isTrashed)
        #expect(root.isTrashed)
    }

    @Test func moveRejectsCycles() {
        let context = makeContext()
        let (store, root, _, grandchild, other) = makeTree(context)

        // Legal: move root under other.
        store.move(root, toParent: other, in: allNotes(context))
        #expect(root.parentNoteID == other.id)

        // Illegal: move other under its own grandchild-through-root subtree.
        store.move(other, toParent: grandchild, in: allNotes(context))
        #expect(other.parentNoteID == nil) // unchanged — cycle refused

        // Illegal: move a page under itself.
        store.move(root, toParent: root, in: allNotes(context))
        #expect(root.parentNoteID == other.id)
    }

    @Test func duplicateDeepCopiesSubtreeAndRemapsReferences() throws {
        let context = makeContext()
        let store = NotesStore(context: context)
        let root = store.createPage(title: "Template")
        let child = store.createPage(title: "Child", parent: root)

        // Root content: a paragraph + a subpage embed referencing the child.
        let doc = PMNode(type: "doc", content: [
            PMNode(type: "paragraph", content: [.text("hello")]),
            PMNode(type: "subpage", attrs: [
                "noteID": .string(child.id.uuidString),
                "title": .string("Child"),
            ]),
        ])
        store.save(doc, to: root)

        // Child is a database with one filled cell and a saved view.
        let dbStore = DatabaseStore(context: context)
        dbStore.seedNewDatabase(child)
        let name = dbStore.fetchProperties(databaseNoteID: child.id)[0]
        let row = dbStore.fetchRows(databaseNoteID: child.id)[0]
        var cell = DBCellValue()
        cell.text = "cell"
        dbStore.setValue(cell, rowID: row.id, propertyID: name.id, in: child)
        var view = DBViewConfig()
        view.name = "Mine"
        var sort = DBSort()
        sort.propertyID = name.id
        view.sorts = [sort]
        dbStore.upsertView(view, on: child)
        try context.save()

        let propertiesBefore = try context.fetchCount(FetchDescriptor<DBProperty>())
        let copy = store.duplicate(root, in: allNotes(context))
        try context.save()

        #expect(copy.title == "Template copy")
        #expect(copy.id != root.id)

        // The subtree came along, as new notes.
        let all = allNotes(context)
        let copiedChild = try #require(all.first { $0.parentNoteID == copy.id })
        #expect(copiedChild.id != child.id)
        #expect(copiedChild.kind == .database)

        // Database payload doubled, with remapped ids.
        #expect(try context.fetchCount(FetchDescriptor<DBProperty>()) == propertiesBefore * 2)
        let copiedTitles = dbStore.rowTitles(databaseNoteID: copiedChild.id).map(\.title)
        #expect(copiedTitles.contains("cell"))
        // The saved view's sort re-points at the COPIED property.
        let copiedView = try #require(dbStore.views(of: copiedChild).first)
        let copiedName = dbStore.fetchProperties(databaseNoteID: copiedChild.id)[0]
        #expect(copiedView.sorts?.first?.propertyID == copiedName.id)

        // The copied subpage embed points at the COPIED child, not the original.
        let copiedJSON = (copy.blocks ?? [])
            .map { String(decoding: $0.contentJSON, as: UTF8.self) }
            .joined()
        #expect(copiedJSON.contains(copiedChild.id.uuidString))
        #expect(!copiedJSON.contains(child.id.uuidString))

        // The original is untouched.
        #expect((root.blocks ?? []).count == 2)
        #expect(store.descendants(of: root, in: all).count == 1)
    }

    @Test func pagePropsRoundTripAndEmptyEncodesNil() {
        var props = PageProps()
        #expect(props.encoded() == nil) // untouched pages stay byte-identical

        props.coverKind = "gradient"
        props.coverHex = "#3E8EF7"
        props.coverHex2 = "#8B7CF6"
        props.coverOffsetY = 0.25
        props.wideLayout = true
        let data = props.encoded()
        #expect(data != nil)
        let decoded = PageProps.decode(data)
        #expect(decoded == props)
        #expect(decoded.hasCover)
    }

    @Test func permanentDeletePurgesSubtreeIncludingDatabases() {
        let context = makeContext()
        let (store, root, child, _, _) = makeTree(context)

        // Make the child a database with a value, to prove the purge runs
        // down the subtree.
        let dbStore = DatabaseStore(context: context)
        dbStore.seedNewDatabase(child)
        let property = dbStore.fetchProperties(databaseNoteID: child.id)[0]
        let row = dbStore.fetchRows(databaseNoteID: child.id)[0]
        var cell = DBCellValue()
        cell.text = "cell"
        dbStore.setValue(cell, rowID: row.id, propertyID: property.id, in: child)
        try? context.save()

        store.delete(root, in: allNotes(context))
        store.deletePermanently(root, in: allNotes(context))
        try? context.save()

        #expect((try? context.fetchCount(FetchDescriptor<Note>())) == 1) // "Other"
        #expect((try? context.fetchCount(FetchDescriptor<DBProperty>())) == 0)
        #expect((try? context.fetchCount(FetchDescriptor<DBRow>())) == 0)
        #expect((try? context.fetchCount(FetchDescriptor<DBValue>())) == 0)
    }
}
