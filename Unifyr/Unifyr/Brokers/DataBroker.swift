//
//  DataBroker.swift
//  Unifyr
//
//  §3 — the Broker Layer contract. One actor per domain. The UI and the MCP
//  tools are BOTH consumers of brokers; a broker is never a UI detail. Every
//  public broker verb MUST get a corresponding MCP tool (§7), so keep verbs
//  coarse, Sendable-in/Sendable-out, and free of framework types at the
//  boundary — brokers return value snapshots, never EKEvent/CNContact/etc.
//

import Foundation

/// Common protocol: async CRUD + `AsyncStream<Change>` (§3).
///
/// Domains that span two natural item types (e.g. EventKit = events +
/// reminders) conform for their primary item and expose the rest as
/// domain-specific verbs, per §3 ("Each broker also exposes domain-specific
/// verbs").
protocol DataBroker: Actor {
    associatedtype Item: Identifiable & Sendable where Item.ID: Sendable

    /// Request the TCC permission this broker needs. Called lazily on first
    /// module open (§6) — never eagerly at launch.
    func requestAccess() async throws

    /// Read snapshots matching `query`.
    func fetch(_ query: BrokerQuery) async throws -> [Item]

    /// Coarse change feed. Underlying frameworks (EventKit, Contacts) emit
    /// store-wide notifications, so `.reloaded` is the common signal; finer
    /// deltas are delivered when a source provides them.
    func changes() -> AsyncStream<BrokerChange<Item>>
}

/// A uniform, Sendable query passed to `fetch`. Not every field applies to
/// every broker; brokers read the fields they understand and ignore the rest.
nonisolated struct BrokerQuery: Sendable {
    var searchText: String?
    var dateRange: ClosedRange<Date>?
    var limit: Int?
    /// Reminders: include already-completed items.
    var includeCompleted: Bool

    init(
        searchText: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        limit: Int? = nil,
        includeCompleted: Bool = false
    ) {
        self.searchText = searchText
        self.dateRange = dateRange
        self.limit = limit
        self.includeCompleted = includeCompleted
    }

    /// Everything, unfiltered.
    static let all = BrokerQuery()
}

/// A change emitted by a broker's `changes()` stream.
nonisolated enum BrokerChange<Item>: Sendable
where Item: Identifiable & Sendable, Item.ID: Sendable {
    case inserted(Item)
    case updated(Item)
    case deleted(Item.ID)
    /// The backing store changed in a way too coarse to diff (EventKit /
    /// Contacts store notifications). Consumers should re-`fetch`.
    case reloaded
}

/// Uniform authorization state across brokers, decoupled from framework enums.
nonisolated enum BrokerAuthorization: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    /// System granted only partial access (e.g. Photos limited library).
    case limited
}

/// Errors surfaced across the broker boundary. Framework errors are wrapped so
/// callers (UI and MCP alike) never depend on EventKit/Contacts error types.
nonisolated enum BrokerError: Error, Sendable {
    case accessDenied
    case accessRestricted
    case notFound
    case invalidInput(String)
    case underlying(String)
}
