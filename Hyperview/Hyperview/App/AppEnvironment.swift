//
//  AppEnvironment.swift
//  Hyperview
//
//  The broker registry. Brokers are actors (Sendable), created once and shared
//  by every consumer — the SwiftUI views today, the in-app Claude layer and the
//  MCP server later (§3: "the UI and the MCP tools are both consumers of the
//  broker layer"). Injected through the SwiftUI environment.
//

import SwiftUI
import SwiftData

/// Shared, long-lived broker instances. Add one line per new broker.
struct Brokers: Sendable {
    let eventKit: EventKitBroker
    let contacts: ContactsBroker
    let photos: PhotoBroker

    init(
        eventKit: EventKitBroker = EventKitBroker(),
        contacts: ContactsBroker = ContactsBroker(),
        photos: PhotoBroker = PhotoBroker()
    ) {
        self.eventKit = eventKit
        self.contacts = contacts
        self.photos = photos
    }
}

extension EnvironmentValues {
    /// Access with `@Environment(\.brokers)`.
    @Entry var brokers = Brokers()

    /// The dedicated, non-CloudKit mail cache container (D9). Injected by the
    /// app; the Mail module applies it to its own subtree so its `@Query`s and
    /// context read the mail store, not the CloudKit notes store.
    @Entry var mailContainer: ModelContainer? = nil

    /// App-wide mail orchestration (shared by the Mail UI and the MCP tools, so
    /// connections survive tab switches and both see the same state).
    @Entry var mailService: MailService? = nil

    /// The MCP surface (server toggle, config, audit) — §7.
    @Entry var mcp: MCPController? = nil

    /// Local store holding the MCP audit log.
    @Entry var automationContainer: ModelContainer? = nil
}
