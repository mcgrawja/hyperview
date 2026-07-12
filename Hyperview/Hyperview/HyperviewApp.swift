//
//  HyperviewApp.swift
//  Hyperview
//
//  App entry. Owns the shared SwiftData container (the full §4 schema, dormant
//  entities included) and the broker registry, and injects both into the
//  environment so every view — and, later, the Claude/MCP layer — draws from
//  one source.
//

import SwiftUI
import SwiftData

@main
struct HyperviewApp: App {
    private let modelContainer: ModelContainer
    private let mailContainer: ModelContainer
    private let automationContainer: ModelContainer
    private let brokers = Brokers()
    private let mailService: MailService
    private let mcp: MCPController
    private let claudeChat: ClaudeChatController
    private let messagesDB = MessagesDatabase()
    private let tagsStore: TagsStore

    init() {
        // Flush stdout immediately so diagnostic logs appear in real time even
        // when stdout is redirected to a file (not a TTY).
        setvbuf(stdout, nil, _IONBF, 0)
        modelContainer = HyperviewSchema.makeContainer()
        mailContainer = MailStore.makeContainer()
        automationContainer = AutomationStore.makeContainer()

        // Phase-2 gate: make sure every record type (dormant entities
        // included) exists in the CloudKit development schema (§9 / D7).
        CloudKitSchemaSeeder.initializeIfNeeded()

        // TEMPORARY: Messages module bring-up probe (see MessagesDiagnostics).
        MessagesDiagnostics.run()

        // Unify Mail's old tag data into the universal system, then stand up
        // the shared tags window (Mail + rules use it; other modules @Query).
        TagsStore.migrateMailTagsIfNeeded(mailContainer: mailContainer, mainContainer: modelContainer)
        let tags = TagsStore(container: modelContainer)
        tagsStore = tags

        let service = MailService()
        service.context = mailContainer.mainContext
        service.universalTagLink = { [weak tags] tagID, header in
            tags?.link(tagID, kind: TagKind.mail, key: header)
        }
        service.startAutoRefresh()
        mailService = service

        mcp = MCPController(
            brokers: brokers,
            notesContainer: modelContainer,
            mailContainer: mailContainer,
            mailService: service,
            automationContainer: automationContainer
        )

        let chat = ClaudeChatController()
        chat.attach(mcp: mcp)
        claudeChat = chat
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.brokers, brokers)
                .environment(\.mailContainer, mailContainer)
                .environment(\.mailService, mailService)
                .environment(\.mcp, mcp)
                .environment(\.automationContainer, automationContainer)
                .environment(\.claudeChat, claudeChat)
                .environment(\.messagesDB, messagesDB)
                .environment(\.tagsStore, tagsStore)
        }
        .modelContainer(modelContainer)
    }
}
