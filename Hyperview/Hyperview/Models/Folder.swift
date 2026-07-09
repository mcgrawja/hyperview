//
//  Folder.swift
//  Hyperview
//
//  §4.2 — v1 active entity. Folders form a tree via `parentFolderID` (UUID
//  convention, not a relationship) so the sidebar survives partial sync.
//

import Foundation
import SwiftData

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = "Untitled"
    var parentFolderID: UUID? = nil
    var sortKey: String = ""
    var emoji: String? = nil

    /// Inverse of `Note.folder`. CloudKit integration REQUIRES every
    /// relationship to have an inverse (§4.1 exists for exactly these rules),
    /// so the Note↔Folder link is declared on this side. `.nullify` (never
    /// `.deny`, per §4.1): deleting a folder orphans its notes rather than
    /// deleting them. The folder *tree* still uses `parentFolderID` (UUID
    /// convention), not a relationship.
    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note]? = []

    init(
        name: String = "Untitled",
        parentFolderID: UUID? = nil,
        sortKey: String = "",
        emoji: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.parentFolderID = parentFolderID
        self.sortKey = sortKey
        self.emoji = emoji
    }
}
