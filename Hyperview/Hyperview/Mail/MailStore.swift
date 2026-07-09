//
//  MailStore.swift
//  Hyperview
//
//  The mail cache's dedicated ModelContainer — deliberately SEPARATE from the
//  app's CloudKit-backed notes store (D9). `cloudKitDatabase: .none` and a
//  distinct on-disk store guarantee mail never touches the CloudKit private
//  database; each device rebuilds this cache from its servers.
//

import Foundation
import SwiftData

enum MailStore {
    static let schema = Schema([
        MailAccount.self,
        Mailbox.self,
        MailMessage.self,
        MailAttachment.self,
        MailTag.self,
        MailTagAssignment.self,
        SmartMailbox.self,
        MailRule.self,
    ])

    @MainActor
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(
            "MailCache",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create Hyperview MailStore container: \(error)")
        }
    }
}
