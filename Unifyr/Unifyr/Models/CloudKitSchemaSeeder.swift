//
//  CloudKitSchemaSeeder.swift
//  Unifyr
//
//  Phase-2 gate prerequisite (§9 / D7): the CloudKit development schema must
//  contain EVERY record type — dormant entities included — before the one-time
//  production promotion.
//
//  The proper mechanism is NSPersistentCloudKitContainer's
//  initializeCloudKitSchema(), which uploads the full model's record types
//  without needing real records. (A create-then-delete of throwaway records
//  does NOT work: the async mirroring export coalesces history, so
//  insert+delete nets to nothing exported.) SwiftData doesn't expose the API,
//  so this bridges the SwiftData model into a throwaway Core Data container
//  solely for schema initialization.
//

import Foundation
import CoreData
import SwiftData

nonisolated enum CloudKitSchemaSeeder {
    // v3: HVTag/HVTagLink added — re-run so the new record types register in
    // the CloudKit development schema (then deploy to production in Console).
    // v4: Note.deletedAt / Note.trashedFromFolderID (the Notes trash). New
    // FIELDS on an existing record type still need re-seeding, and still need a
    // production deploy before an archived build will sync them.
    private static let flag = "cloudkit.schemaInitialized.v4"

    /// One-shot, off the main thread (the upload can take a little while).
    static func initializeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        Task.detached(priority: .utility) {
            do {
                try initializeSchema()
                UserDefaults.standard.set(true, forKey: flag)
                MailLog.log("[CloudKit] full schema initialized in development environment — all record types registered")
            } catch {
                MailLog.log("[CloudKit] schema initialization failed: \(error.localizedDescription)")
            }
        }
    }

    private static func initializeSchema() throws {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: UnifyrSchema.models) else {
            throw NSError(domain: "Unifyr", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "SwiftData → Core Data model conversion failed"])
        }
        // Throwaway store — schema init only; never read again.
        let storeURL = URL.applicationSupportDirectory.appending(path: "CloudKitSchemaInit.sqlite")
        let description = NSPersistentStoreDescription(url: storeURL)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.com.mcgraw.Hyperview"
        )

        let container = NSPersistentCloudKitContainer(name: "SchemaInit", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        // Synchronously creates every record type + field in the CloudKit
        // DEVELOPMENT environment. Requires network + iCloud signed in.
        try container.initializeCloudKitSchema(options: [])
    }
}
