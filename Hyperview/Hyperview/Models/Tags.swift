//
//  Tags.swift
//  Hyperview
//
//  Universal tag system: one tag vocabulary shared by every module, stored in
//  the CloudKit notes container so tags sync to the future iOS/iPadOS builds.
//  ADDITIVE to the production schema (never rename/remove fields — §4.1).
//
//  Links are (tagID, itemKind, itemKey) triples with NO relationships (keeps
//  CloudKit inverses out of it). `itemKey` is each module's stable identity:
//    note      → Note.id uuidString
//    reminder  → EKReminder calendarItemIdentifier
//    event     → EKEvent eventIdentifier
//    contact   → CNContact identifier
//    chat      → chat.guid
//    mail      → Message-ID header (matches MailTagAssignment's keying)
//
//  Files deliberately use FINDER tags instead (visible in Apple's own apps) —
//  see DriveView.
//

import Foundation
import SwiftData

@Model
final class HVTag {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#3E8EF7"
    var sortKey: String = ""
    var createdAt: Date = Date()

    init(name: String, colorHex: String = "#3E8EF7") {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.createdAt = Date()
    }
}

@Model
final class HVTagLink {
    var id: UUID = UUID()
    var tagID: UUID? = nil
    var itemKind: String = ""
    var itemKey: String = ""
    var createdAt: Date = Date()

    init(tagID: UUID, itemKind: String, itemKey: String) {
        self.id = UUID()
        self.tagID = tagID
        self.itemKind = itemKind
        self.itemKey = itemKey
        self.createdAt = Date()
    }
}

/// The item kinds the universal tag system covers.
nonisolated enum TagKind {
    static let note = "note"
    static let reminder = "reminder"
    static let event = "event"
    static let contact = "contact"
    static let chat = "chat"
    static let mail = "mail"
    // NOTE: no "file" kind — Drive uses real Finder tags (file metadata that
    // iCloud Drive syncs with the file and Apple's apps display). Reaffirmed
    // by the owner 2026-07-11 after briefly trying universal tags there.
}
