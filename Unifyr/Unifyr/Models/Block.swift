//
//  Block.swift
//  Unifyr
//
//  §4.2 — v1 active entity. A block is one node of a note's TipTap document.
//  Nesting is expressed by `parentBlockID` (a UUID reference, NOT a SwiftData
//  relationship) so partial CloudKit syncs never dangle. Ordering is by String
//  `sortKey`.
//

import Foundation
import SwiftData

@Model
final class Block {
    var id: UUID = UUID()
    var note: Note? = nil
    /// Nesting/indent parent, by UUID convention (not a relationship).
    var parentBlockID: UUID? = nil
    /// Fractional/lexicographic ordering among siblings.
    var sortKey: String = ""
    /// See `BlockKind`. Stored as String for CloudKit schema stability.
    var kind: String = BlockKind.paragraph.rawValue
    /// TipTap node JSON for this block (the BlockSerializer round-trips this).
    var contentJSON: Data = Data()
    /// Todo blocks only.
    var isChecked: Bool = false
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    // Dormant until Databases ship (D7): a block that is the page content of a
    // database row carries that row's id here.
    var rowID: UUID? = nil

    init(
        note: Note? = nil,
        parentBlockID: UUID? = nil,
        sortKey: String = "",
        kind: BlockKind = .paragraph,
        contentJSON: Data = Data()
    ) {
        self.id = UUID()
        self.note = note
        self.parentBlockID = parentBlockID
        self.sortKey = sortKey
        self.kind = kind.rawValue
        self.contentJSON = contentJSON
        self.isChecked = false
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}

/// The block vocabulary (§4.2 + Notion-refocus additions). Stored as String on
/// `Block.kind` — adding a case is NOT a CloudKit schema change.
/// `nonisolated` — a pure value type used by the (nonisolated) BlockSerializer.
nonisolated enum BlockKind: String, Sendable, CaseIterable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bullet
    case numbered
    case todo
    case quote
    case code
    case divider
    case image
    case table
    case callout
    /// Collapsible toggle (Phase 2, 2026-07-22): content = summary + body.
    case toggle
    /// Inline child-page embed (Phase 3): attrs = noteID + cached title/emoji.
    case subpage
    /// Inline database-view embed (Phase 4): attrs = noteID (the database
    /// note) + viewID + cached title/emoji. Preview data is fetched live.
    case dbembed
    /// Column layout (Phase 5): content = 2–4 column nodes, passed through.
    case columns
    /// Web bookmark card (integration round): attrs = url + fetched title.
    case bookmark
    /// Live agenda slice (integration round 2): attrs = scope; data is
    /// fetched fresh on every load, never persisted.
    case agenda
}

extension Block {
    var blockKind: BlockKind {
        get { BlockKind(rawValue: kind) ?? .paragraph }
        set { kind = newValue.rawValue }
    }
}
