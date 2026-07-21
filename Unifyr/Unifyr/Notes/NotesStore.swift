//
//  NotesStore.swift
//  Unifyr
//
//  The Notes data layer for the UI/editor (Phase 2). Operates on the view's
//  MainActor `ModelContext` so it stays consistent with `@Query`-driven lists
//  and the open editor. The MCP-facing `NotesBroker` actor (Phase 6, §7) wraps
//  these same operations for automation.
//
//  Persistence model: the editor is the authority on document order and emits
//  the FULL document (§5 `documentChanged`). `save(_:to:)` reconciles that
//  document against the note's stored blocks by position — updating in place,
//  inserting new, deleting removed — so block records (and their UUIDs) are
//  stable for append/edit. Reorders may reattach a UUID to different content;
//  that's an accepted v1 simplification (editor-carried block IDs harden it
//  later), and the persisted result is always correct in content and order.
//

import Foundation
import SwiftData

/// Editor ↔ NotesView signals. Declared here (not in the macOS-only editor
/// bridge) so both platforms — and Universal Search — can reference them.
extension Notification.Name {
    /// JS asked for the note picker (slash command "Link to note").
    static let unifyrRequestNoteLink = Notification.Name("unifyr.requestNoteLink")
    /// NotesView picked a note; userInfo: ["href": String, "text": String].
    static let unifyrInsertNoteLink = Notification.Name("unifyr.insertNoteLink")
    /// A hyperview://note/<uuid> link was clicked; userInfo: ["id": UUID].
    static let unifyrOpenNote = Notification.Name("unifyr.openNote")
    /// iOS: the editor asked for a file link — NotesView shows the document
    /// picker (macOS uses an NSOpenPanel inside the bridge instead).
    static let unifyrRequestFileLink = Notification.Name("unifyr.requestFileLink")
    /// iOS: a file:// link was clicked; userInfo: ["href": String]. NotesView
    /// previews it with Quick Look.
    static let unifyrOpenFileLink = Notification.Name("unifyr.openFileLink")
}

@MainActor
struct NotesStore {
    let context: ModelContext

    // MARK: Create

    @discardableResult
    func createNote(title: String = "", folder: Folder? = nil) -> Note {
        let siblings = folderNotes(folder)
        let note = Note(
            title: title,
            folder: folder,
            sortKey: FractionalIndex.keyAfter(siblings.last?.sortKey)
        )
        context.insert(note)
        return note
    }

    @discardableResult
    func createFolder(name: String = "New Folder", parent: Folder? = nil) -> Folder {
        let siblings = folders(parentID: parent?.id)
        let folder = Folder(
            name: name,
            parentFolderID: parent?.id,
            sortKey: FractionalIndex.keyAfter(siblings.last?.sortKey)
        )
        context.insert(folder)
        return folder
    }

    // MARK: Document load / save (editor bridge, §5)

    /// Assemble the note's blocks into a TipTap document (Swift → JS
    /// `loadDocument`).
    func loadDocument(_ note: Note) -> PMNode {
        BlockSerializer.document(from: note.blocks ?? [])
    }

    /// Reconcile a full document back into the note's blocks (JS → Swift
    /// `documentChanged`).
    func save(_ document: PMNode, to note: Note) {
        let contents = BlockSerializer.blocks(from: document)
        let existing = (note.blocks ?? []).sorted { $0.sortKey < $1.sortKey }
        let keys = FractionalIndex.keys(count: contents.count)

        for (index, content) in contents.enumerated() {
            let block: Block
            if index < existing.count {
                block = existing[index]
            } else {
                block = Block(note: note)
                context.insert(block)
            }
            BlockSerializer.apply(content, to: block)
            // Guarded: assigning an identical value still dirties the row.
            if block.sortKey != keys[index] { block.sortKey = keys[index] }
        }

        if existing.count > contents.count {
            for stale in existing[contents.count...] {
                context.delete(stale)
            }
        }
        note.modifiedAt = Date()
    }

    // MARK: Block actions

    /// Toggle a todo block's checked state (JS → Swift `blockAction`, and the
    /// future `notes_toggle_todo` tool).
    func toggleTodo(_ block: Block) {
        guard block.blockKind == .todo else { return }
        block.isChecked.toggle()
        block.modifiedAt = Date()
        block.note?.modifiedAt = Date()
    }

    // MARK: Delete / archive

    /// SOFT-delete: move the note to the trash. Everything that lists notes
    /// filters `isTrashed` out, so this reads as a delete — but it's reversible,
    /// which the old `context.delete` (cascading straight through the blocks)
    /// was not.
    func delete(_ note: Note) {
        note.trashedFromFolderID = note.folder?.id
        note.deletedAt = Date()
        note.folder = nil
        note.modifiedAt = Date()
    }

    /// Put a trashed note back where it came from, if that folder still exists.
    func restore(_ note: Note, folders: [Folder]) {
        note.folder = folders.first { $0.id == note.trashedFromFolderID }
        note.deletedAt = nil
        note.trashedFromFolderID = nil
        note.modifiedAt = Date()
    }

    /// The real, irreversible delete — only ever reached from the trash.
    func deletePermanently(_ note: Note) {
        purgeExternalReferences(of: note)
        context.delete(note) // cascades to blocks (§4 delete rule)
    }

    func emptyTrash(_ notes: [Note]) {
        for note in notes where note.isTrashed {
            purgeExternalReferences(of: note)
            context.delete(note)
        }
    }

    /// Assets, tag links, and database data (properties/rows/values, §4.3)
    /// reference the note by UUID, not by relationship, so the cascade doesn't
    /// reach them — without this they'd be orphaned forever (and stale links
    /// inflate tag counts).
    private func purgeExternalReferences(of note: Note) {
        let noteID = note.id
        let noteKey = note.id.uuidString
        DatabaseStore(context: context).purgeDatabaseData(noteID: noteID)
        if let assets = try? context.fetch(FetchDescriptor<Asset>(
            predicate: #Predicate { $0.noteID == noteID }
        )) {
            for asset in assets { context.delete(asset) }
        }
        if let links = try? context.fetch(FetchDescriptor<HVTagLink>(
            predicate: #Predicate { $0.itemKind == "note" && $0.itemKey == noteKey }
        )) {
            for link in links { context.delete(link) }
        }
    }

    func archive(_ note: Note, _ archived: Bool = true) {
        note.isArchived = archived
        note.modifiedAt = Date()
    }

    // MARK: - Private lookups

    // Only the LAST sibling's sort key is ever needed (for keyAfter), so both
    // lookups push filter+sort+limit into the store instead of fetching the
    // whole table and narrowing in Swift.

    private func folderNotes(_ folder: Folder?) -> [Note] {
        let folderID = folder?.id
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.folder?.id == folderID && !$0.isArchived },
            sortBy: [SortDescriptor(\.sortKey, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let last = (try? context.fetch(descriptor)) ?? []
        return last.reversed()
    }

    private func folders(parentID: UUID?) -> [Folder] {
        var descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.parentFolderID == parentID },
            sortBy: [SortDescriptor(\.sortKey, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let last = (try? context.fetch(descriptor)) ?? []
        return last.reversed()
    }
}

/// Lexicographic (fractional) sort keys — String, never integer reindexing
/// (§4.1). Fixed-width base-36 so string order == numeric order, with gaps left
/// for cheap insertion.
enum FractionalIndex {
    private static let step = 1_000
    private static let radix = 36
    private static let width = 8 // fits ~36^8 positions; ample

    /// `count` evenly spaced keys.
    static func keys(count: Int) -> [String] {
        guard count > 0 else { return [] }
        return (1...count).map { encode($0 * step) }
    }

    /// A key that sorts immediately after `previous` (or a first key if nil).
    static func keyAfter(_ previous: String?) -> String {
        guard let previous, let value = Int(previous, radix: radix) else {
            return encode(step)
        }
        return encode(value + step)
    }

    /// A key between two keys (for future mid-list insertion).
    static func keyBetween(_ lower: String?, _ upper: String?) -> String {
        let lo = lower.flatMap { Int($0, radix: radix) } ?? 0
        let hi = upper.flatMap { Int($0, radix: radix) } ?? (lo + 2 * step)
        return encode((lo + hi) / 2)
    }

    private static func encode(_ value: Int) -> String {
        let s = String(value, radix: radix)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
