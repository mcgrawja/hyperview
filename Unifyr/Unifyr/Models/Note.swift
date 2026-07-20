//
//  Note.swift
//  Unifyr
//
//  §4.2 — v1 active entity. CloudKit hard rules (§4.1) are enforced: every
//  stored property has a default or is optional, all relationships are optional,
//  no #Unique, no .deny delete rules, String (fractional) sort keys.
//
//  DO NOT rename or remove a stored field after the Phase-2 production schema
//  push. Deprecate in place.
//

import Foundation
import SwiftData

@Model
final class Note {
    var id: UUID = UUID()
    var title: String = ""
    var emoji: String? = nil
    var folder: Folder? = nil
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var isArchived: Bool = false
    /// Fractional/lexicographic ordering within the folder (§4.1). Never reindex.
    var sortKey: String = ""

    // MARK: Trash
    //
    // Deleting a note SOFT-deletes it: `context.delete` was unrecoverable, and a
    // note is the kind of thing you delete at 1am and want back at 9am. Trashed
    // notes are excluded from every list and hidden from search; "Recently
    // Deleted" is the one place they surface.

    /// When the note was trashed. `nil` for a live note.
    var deletedAt: Date? = nil
    /// The folder it was in when trashed, so Restore puts it BACK rather than
    /// dumping it at the top level. (An id, not a relationship: the folder may
    /// itself be deleted while the note sits in the trash.)
    var trashedFromFolderID: UUID? = nil

    var isTrashed: Bool { deletedAt != nil }

    @Relationship(deleteRule: .cascade, inverse: \Block.note)
    var blocks: [Block]? = []

    // Dormant until "Unifyr 1.5: Databases" (D7). Present so the production
    // CloudKit schema already contains them; unused in v1.
    /// "page" | "database" — always "page" in v1.
    var noteKind: String = NoteKind.page.rawValue
    /// Database property definitions, unused in v1.
    var schemaJSON: Data? = nil

    init(
        title: String = "",
        emoji: String? = nil,
        folder: Folder? = nil,
        sortKey: String = ""
    ) {
        self.id = UUID()
        self.title = title
        self.emoji = emoji
        self.folder = folder
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.isArchived = false
        self.sortKey = sortKey
        self.noteKind = NoteKind.page.rawValue
    }
}

/// Typed view over `Note.noteKind` (stored as String for CloudKit stability).
enum NoteKind: String, Sendable {
    case page
    case database
}

extension Note {
    var kind: NoteKind {
        get { NoteKind(rawValue: noteKind) ?? .page }
        set { noteKind = newValue.rawValue }
    }
}
