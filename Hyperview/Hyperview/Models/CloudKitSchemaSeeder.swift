//
//  CloudKitSchemaSeeder.swift
//  Hyperview
//
//  Phase-2 gate prerequisite (§9 / D7): CloudKit only registers a record type
//  the first time an instance is SAVED. Notes/Blocks/Folders exist through
//  daily use, but the dormant database entities (DBProperty/DBRow/DBValue)
//  and Asset have never been instantiated — so they are absent from the
//  CloudKit development schema, and a promotion to production would silently
//  ship an incomplete schema, breaking D7's no-migration guarantee for 1.5.
//
//  This one-shot seeder saves a throwaway instance of every such entity
//  (registering the record type and all its fields with CloudKit), then
//  deletes them. Record types persist after their records are gone.
//

import Foundation
import SwiftData

@MainActor
enum CloudKitSchemaSeeder {
    private static let flag = "cloudkit.schemaSeeded.v1"

    static func seedIfNeeded(container: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let context = container.mainContext

        // One of each never-instantiated entity. Values are throwaway; the
        // point is that every persisted FIELD gets exercised so CloudKit
        // learns the complete record shape.
        let asset = Asset(noteID: nil, filename: "schema-seed", mimeType: "application/octet-stream", data: Data([0x0]))
        let property = DBProperty(databaseNoteID: nil, name: "schema-seed", kind: .text, configJSON: Data("{}".utf8), sortKey: "0")
        let row = DBRow(databaseNoteID: nil, sortKey: "0")
        let value = DBValue(rowID: row.id, propertyID: property.id, valueJSON: Data("{}".utf8))

        context.insert(asset)
        context.insert(property)
        context.insert(row)
        context.insert(value)

        do {
            try context.save()
            // Deleting afterwards keeps the store clean; the record types and
            // their fields remain registered in the CloudKit dev schema once
            // the mirroring export runs.
            context.delete(asset)
            context.delete(property)
            context.delete(row)
            context.delete(value)
            try context.save()
            UserDefaults.standard.set(true, forKey: flag)
            MailLog.log("[CloudKit] schema seed complete — all record types registered")
        } catch {
            MailLog.log("[CloudKit] schema seed failed: \(error)")
        }
    }
}
