//
//  UnifyrApp.swift
//  Unifyr
//
//  App entry. Owns the shared SwiftData container (the full §4 schema, dormant
//  entities included) and the broker registry, and injects both into the
//  environment so every view — and, later, the Claude/MCP layer — draws from
//  one source.
//

import SwiftUI
import SwiftData

@main
struct UnifyrApp: App {
    private let modelContainer: ModelContainer
    private let mailContainer: ModelContainer
    private let automationContainer: ModelContainer
    private let brokers = Brokers()
    private let mailService: MailService
    private let mcp: MCPController
    private let claudeChat: ClaudeChatController
    #if os(macOS)
    private let messagesDB = MessagesDatabase()
    #endif
    private let tagsStore: TagsStore
    private let notificationCoordinator: NotificationCoordinator
    private let contactPhotos = ContactPhotoStore()

    init() {
        // Flush stdout immediately so diagnostic logs appear in real time even
        // when stdout is redirected to a file (not a TTY).
        setvbuf(stdout, nil, _IONBF, 0)
        modelContainer = UnifyrSchema.makeContainer()
        mailContainer = MailStore.makeContainer()
        automationContainer = AutomationStore.makeContainer()

        // Phase-2 gate: make sure every record type (dormant entities
        // included) exists in the CloudKit development schema (§9 / D7).
        CloudKitSchemaSeeder.initializeIfNeeded()

        // TEMPORARY: Messages module bring-up probe (see MessagesDiagnostics).
        #if os(macOS)
        MessagesDiagnostics.run()
        #endif

        // Unify Mail's old tag data into the universal system, then stand up
        // the shared tags window (Mail + rules use it; other modules @Query).
        TagsStore.migrateMailTagsIfNeeded(mailContainer: mailContainer, mainContainer: modelContainer)
        let tags = TagsStore(container: modelContainer)
        tagsStore = tags

        // Unifyr's notification hub — the app becomes the single alert
        // source once Apple's own apps are silenced.
        NotificationService.shared.bootstrap()

        // Mail accounts (settings only — never the cache) ride iCloud's
        // key-value store, so a second device configures itself; the password
        // follows through iCloud Keychain, keyed by the shared account id.
        MailAccountSync.shared.start(context: mailContainer.mainContext)

        let service = MailService()
        service.context = mailContainer.mainContext
        service.universalTagLink = { [weak tags] tagID, header in
            tags?.link(tagID, kind: TagKind.mail, key: header)
        }
        service.onNewMail = { sender, subject in
            NotificationService.shared.notify(kind: .mail, title: sender, body: subject)
        }
        service.startAutoRefresh()
        mailService = service

        #if os(macOS)
        notificationCoordinator = NotificationCoordinator(
            brokers: brokers,
            messagesDB: messagesDB,
            mailService: service
        )
        #else
        notificationCoordinator = NotificationCoordinator(
            brokers: brokers,
            mailService: service
        )
        #endif

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
                // Publish the real size class so every module can pick its
                // layout (iPhone = one pane at a time).
                .resolveCompactLayout()
                .environment(\.brokers, brokers)
                .environment(\.mailContainer, mailContainer)
                .environment(\.mailService, mailService)
                .environment(\.mcp, mcp)
                .environment(\.automationContainer, automationContainer)
                .environment(\.claudeChat, claudeChat)
                #if os(macOS)
                .environment(\.messagesDB, messagesDB)
                #endif
                .environment(\.tagsStore, tagsStore)
                .environment(\.notificationCoordinator, notificationCoordinator)
                .environment(\.contactPhotos, contactPhotos)
        }
        .modelContainer(modelContainer)
    }
}
