//
//  Databases.swift
//  Hyperview
//
//  §4.3 — DORMANT entities. DEFINED in v1 so CloudKit's production schema
//  already contains them (D7), UNUSED until "Hyperview 1.5: Databases".
//
//  Do NOT build UI for these in v1. Do NOT remove them. They ship in the
//  Phase-2 production schema push exactly so 1.5 needs no migration.
//
//  Relations strategy (§4.3): relation values are stored as UUID arrays inside
//  `DBValue.valueJSON` — Notion-style, MCP-traversable, no CloudKit relationship
//  headaches, survives partial syncs.
//

import Foundation
import SwiftData

/// A column definition on a database-kind Note.
@Model
final class DBProperty {
    var id: UUID = UUID()
    var databaseNoteID: UUID? = nil
    var name: String = ""
    /// See `DBPropertyKind`. Stored as String for CloudKit stability.
    var kind: String = DBPropertyKind.text.rawValue
    /// Select options, relation target DB id, etc.
    var configJSON: Data? = nil
    var sortKey: String = ""

    init(
        databaseNoteID: UUID? = nil,
        name: String = "",
        kind: DBPropertyKind = .text,
        configJSON: Data? = nil,
        sortKey: String = ""
    ) {
        self.id = UUID()
        self.databaseNoteID = databaseNoteID
        self.name = name
        self.kind = kind.rawValue
        self.configJSON = configJSON
        self.sortKey = sortKey
    }
}

/// Database property types (§4.3). `rollup` is 2.0+.
enum DBPropertyKind: String, Sendable, CaseIterable {
    case text
    case number
    case select
    case multiSelect
    case date
    case checkbox
    case url
    case person
    case relation
    case rollup // 2.0+
}

extension DBProperty {
    var propertyKind: DBPropertyKind {
        get { DBPropertyKind(rawValue: kind) ?? .text }
        set { kind = newValue.rawValue }
    }
}

/// A row in a database Note. Its page content = `Block`s with `rowID == id`.
@Model
final class DBRow {
    var id: UUID = UUID()
    var databaseNoteID: UUID? = nil
    var sortKey: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init(databaseNoteID: UUID? = nil, sortKey: String = "") {
        self.id = UUID()
        self.databaseNoteID = databaseNoteID
        self.sortKey = sortKey
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}

/// A single cell: the value of one property on one row.
@Model
final class DBValue {
    var id: UUID = UUID()
    var rowID: UUID? = nil
    var propertyID: UUID? = nil
    /// Encoded cell value. Relation values = array of target `DBRow` UUIDs
    /// (UUID refs, not SwiftData relationships).
    var valueJSON: Data = Data()

    init(rowID: UUID? = nil, propertyID: UUID? = nil, valueJSON: Data = Data()) {
        self.id = UUID()
        self.rowID = rowID
        self.propertyID = propertyID
        self.valueJSON = valueJSON
    }
}
