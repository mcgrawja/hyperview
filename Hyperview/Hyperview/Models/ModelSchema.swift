//
//  ModelSchema.swift
//  Hyperview
//
//  Single source of truth for the SwiftData schema and the shared
//  ModelContainer. Every @Model in §4 — active AND dormant (§4.3) — MUST be
//  listed here so the Phase-2 production CloudKit schema contains the full set
//  (D7). The Phase-gate review (§9) reviews exactly this list.
//

import Foundation
import SwiftData

enum HyperviewSchema {
    /// The complete entity set. Order is not significant; completeness is.
    static let models: [any PersistentModel.Type] = [
        // Active (v1)
        Note.self,
        Block.self,
        Folder.self,
        Asset.self,
        // Dormant until "Hyperview 1.5: Databases" (§4.3) — listed so they ship
        // in the production schema and 1.5 needs no migration.
        DBProperty.self,
        DBRow.self,
        DBValue.self,
    ]

    static let schema = Schema(models)

    /// Builds the app's shared container.
    ///
    /// `cloudKitDatabase: .automatic` uses the CloudKit **private** database
    /// (D2) when the iCloud entitlement is present, and falls back to a purely
    /// local store otherwise — so development before the Phase-2 schema push
    /// stays local without a code change.
    @MainActor
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create Hyperview ModelContainer: \(error)")
        }
    }
}
