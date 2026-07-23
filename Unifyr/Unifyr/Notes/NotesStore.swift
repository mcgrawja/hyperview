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
    /// iOS: the editor asked for an image (slash "Image") — NotesView shows the
    /// image picker (macOS uses an NSOpenPanel inside the bridge instead).
    static let unifyrRequestImageFile = Notification.Name("unifyr.requestImageFile")
    /// NotesView picked an image file; userInfo: ["url": URL]. The bridge
    /// stores it as an Asset and inserts the image block.
    static let unifyrInsertImageFile = Notification.Name("unifyr.insertImageFile")
}

@MainActor
struct NotesStore {
    let context: ModelContext

    // MARK: Create

    /// Create a page under `parent` (nil = top level). Notion model: pages
    /// nest inside pages; folders are gone from the UI.
    @discardableResult
    func createPage(title: String = "", parent: Note? = nil) -> Note {
        let note = Note(
            title: title,
            sortKey: FractionalIndex.keyAfter(lastChildSortKey(parentID: parent?.id))
        )
        note.parentNoteID = parent?.id
        context.insert(note)
        return note
    }

    /// Legacy entry point (MCP notes_create) — a top-level page now.
    @discardableResult
    func createNote(title: String = "", folder: Folder? = nil) -> Note {
        createPage(title: title, parent: nil)
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
    /// `loadDocument`), with page-reference labels refreshed from live data.
    func loadDocument(_ note: Note) -> PMNode {
        BlockSerializer.refreshingPageRefs(
            BlockSerializer.document(from: note.blocks ?? []),
            resolve: pageRefResolver()
        )
    }

    /// Live title/emoji for a referenced page (subpage embeds, @-mentions).
    /// Shared with DatabaseStore for row-page documents.
    func pageRefResolver() -> (UUID) -> (title: String, emoji: String?)? {
        { id in
            var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let note = ((try? self.context.fetch(descriptor)) ?? []).first,
                  !note.isTrashed else { return nil }
            return (note.title, note.emoji)
        }
    }

    /// The pages the editor's "@" mention menu can link (recency-ordered).
    func mentionablePages(excluding excludedID: UUID? = nil) -> [(id: UUID, title: String, emoji: String?)] {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.deletedAt == nil && !$0.isArchived },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.id != excludedID }
            .map { ($0.id, $0.title, $0.emoji) }
    }

    /// Pages whose content references `noteID` — link hrefs, @-mentions, and
    /// subpage embeds all carry the target's uuid inside block JSON, so one
    /// byte-scan finds every kind. Personal-scale data keeps this cheap; an
    /// index can come later if it ever isn't.
    func backlinkSources(to noteID: UUID) -> [Note] {
        let upper = noteID.uuidString
        let lower = upper.lowercased()
        let blocks = (try? context.fetch(FetchDescriptor<Block>(
            predicate: #Predicate { $0.note?.deletedAt == nil }
        ))) ?? []
        var seen = Set<UUID>()
        var sources: [Note] = []
        for block in blocks {
            guard let note = block.note,
                  note.id != noteID,
                  !note.isArchived,
                  !seen.contains(note.id) else { continue }
            let json = String(decoding: block.contentJSON, as: UTF8.self)
            guard json.contains(upper) || json.contains(lower) else { continue }
            seen.insert(note.id)
            sources.append(note)
        }
        return sources.sorted { $0.modifiedAt > $1.modifiedAt }
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

    // MARK: Page tree

    /// Every page nested under `note`, to any depth (cycle-guarded). The tree
    /// is UUID-linked, so this is a plain walk over the passed collection.
    func descendants(of note: Note, in all: [Note]) -> [Note] {
        var result: [Note] = []
        var queue: [UUID] = [note.id]
        var seen: Set<UUID> = [note.id]
        while let parentID = queue.first {
            queue.removeFirst()
            for child in all where child.parentNoteID == parentID {
                guard seen.insert(child.id).inserted else { continue }
                result.append(child)
                queue.append(child.id)
            }
        }
        return result
    }

    /// Re-nest a page (nil = top level). The caller guards against moving a
    /// page into its own subtree; this re-checks anyway because a cycle in the
    /// tree is unrecoverable-by-UI.
    func move(_ note: Note, toParent parent: Note?, in all: [Note]) {
        if let parent {
            guard parent.id != note.id,
                  !descendants(of: note, in: all).contains(where: { $0.id == parent.id })
            else { return }
        }
        note.parentNoteID = parent?.id
        note.sortKey = FractionalIndex.keyAfter(lastChildSortKey(parentID: parent?.id, excluding: note.id))
        note.modifiedAt = Date()
    }

    /// Reorder among siblings (`offset` -1 / +1), Database-module style.
    func movePage(_ note: Note, offset: Int, within siblings: [Note]) {
        guard let index = siblings.firstIndex(where: { $0.id == note.id }) else { return }
        let target = index + offset
        guard target >= 0, target < siblings.count else { return }
        if offset < 0 {
            let lower = target - 1 >= 0 ? siblings[target - 1] : nil
            note.sortKey = FractionalIndex.keyBetween(lower?.sortKey, siblings[target].sortKey)
        } else {
            let after = target + 1 < siblings.count ? siblings[target + 1] : nil
            note.sortKey = FractionalIndex.keyBetween(siblings[target].sortKey, after?.sortKey)
        }
        note.modifiedAt = Date()
    }

    func toggleFavorite(_ note: Note) {
        note.isFavorite.toggle()
        note.modifiedAt = Date()
    }

    // MARK: Delete / archive
    //
    // Deleting a page takes its WHOLE subtree to the trash (Notion semantics):
    // children keep their parentNoteID, so restore is just clearing deletedAt
    // back down the subtree. The trash lists only subtree ROOTS.

    /// SOFT-delete the page and everything under it.
    func delete(_ note: Note, in all: [Note]) {
        let now = Date()
        for page in [note] + descendants(of: note, in: all) {
            page.deletedAt = now
            page.modifiedAt = now
        }
    }

    /// Restore the page's subtree. If its old parent is gone or still in the
    /// trash, it comes back at the top level rather than staying invisible.
    func restore(_ note: Note, in all: [Note]) {
        if let parentID = note.parentNoteID {
            let parent = all.first { $0.id == parentID }
            if parent == nil || parent?.isTrashed == true {
                note.parentNoteID = nil
            }
        }
        for page in [note] + descendants(of: note, in: all) {
            page.deletedAt = nil
            page.trashedFromFolderID = nil
            page.modifiedAt = Date()
        }
    }

    /// The real, irreversible delete — only ever reached from the trash.
    /// Takes the subtree with it (children of a purged root would otherwise
    /// dangle forever, invisible).
    func deletePermanently(_ note: Note, in all: [Note]) {
        for page in descendants(of: note, in: all) + [note] {
            purgeExternalReferences(of: page)
            context.delete(page) // cascades to blocks (§4 delete rule)
        }
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

    // Only the LAST sibling's sort key is ever needed (for keyAfter), so these
    // lookups push filter+sort+limit into the store instead of fetching the
    // whole table and narrowing in Swift.

    private func lastChildSortKey(parentID: UUID?, excluding excludedID: UUID? = nil) -> String? {
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.parentNoteID == parentID && $0.deletedAt == nil && !$0.isArchived },
            sortBy: [SortDescriptor(\.sortKey, order: .reverse)]
        )
        descriptor.fetchLimit = 2
        let last = (try? context.fetch(descriptor)) ?? []
        return last.first { $0.id != excludedID }?.sortKey
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
