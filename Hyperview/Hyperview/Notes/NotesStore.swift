//
//  NotesStore.swift
//  Hyperview
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
    static let hyperviewRequestNoteLink = Notification.Name("hyperview.requestNoteLink")
    /// NotesView picked a note; userInfo: ["href": String, "text": String].
    static let hyperviewInsertNoteLink = Notification.Name("hyperview.insertNoteLink")
    /// A hyperview://note/<uuid> link was clicked; userInfo: ["id": UUID].
    static let hyperviewOpenNote = Notification.Name("hyperview.openNote")
    /// iOS: the editor asked for a file link — NotesView shows the document
    /// picker (macOS uses an NSOpenPanel inside the bridge instead).
    static let hyperviewRequestFileLink = Notification.Name("hyperview.requestFileLink")
    /// iOS: a file:// link was clicked; userInfo: ["href": String]. NotesView
    /// previews it with Quick Look.
    static let hyperviewOpenFileLink = Notification.Name("hyperview.openFileLink")
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
            block.sortKey = keys[index]
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

    func delete(_ note: Note) {
        context.delete(note) // cascades to blocks (§4 delete rule)
    }

    func archive(_ note: Note, _ archived: Bool = true) {
        note.isArchived = archived
        note.modifiedAt = Date()
    }

    // MARK: - Private lookups

    private func folderNotes(_ folder: Folder?) -> [Note] {
        let folderID = folder?.id
        let all = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        return all
            .filter { $0.folder?.id == folderID && !$0.isArchived }
            .sorted { $0.sortKey < $1.sortKey }
    }

    private func folders(parentID: UUID?) -> [Folder] {
        let all = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        return all
            .filter { $0.parentFolderID == parentID }
            .sorted { $0.sortKey < $1.sortKey }
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
