//
//  HomeAssistantConfig.swift
//  Unifyr
//
//  The saved Home Assistant connection (base URL + optional vehicle filter),
//  synced across devices via iCloud's key-value store — the same transport the
//  WebDAV servers use (see DriveServers). The long-lived access token rides the
//  synced iCloud Keychain separately, keyed off the base URL.
//
//  There's only ever one connection (a person has one HA), so this is a single
//  record with last-write-wins on `updatedAt`, plus a `deletedAt` tombstone so a
//  disconnect on one device isn't undone by another device pushing its stale copy.
//

import Foundation

/// The saved Home Assistant connection. `pinnedEntities` is the ordered list of
/// entity ids the user chose to show on the dashboard card — synced along with
/// the URL so the same picks appear on every device.
nonisolated struct HomeAssistantConnection: Codable, Hashable, Sendable {
    var urlString: String
    var pinnedEntities: [String]
    var updatedAt: Date

    init(urlString: String, pinnedEntities: [String] = [], updatedAt: Date = Date()) {
        self.urlString = urlString
        self.pinnedEntities = pinnedEntities
        self.updatedAt = updatedAt
    }

    /// Tolerate payloads written before `pinnedEntities` existed (and any future
    /// missing field) so a stored record never fails to decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try c.decode(String.self, forKey: .urlString)
        pinnedEntities = try c.decodeIfPresent([String].self, forKey: .pinnedEntities) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    var url: URL? {
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// The Keychain account for this connection's token. Keyed on the URL so an
    /// edited address gets its own secret rather than shadowing the old one.
    var credentialAccount: String { urlString }
}

@MainActor
@Observable
final class HomeAssistantConfig {
    private static let defaultsKey = "homeassistant.connection"
    private static let syncKey = "homeassistant.connection.v1"
    private static let keychainService = "com.mcgraw.Hyperview.homeassistant"

    private(set) var connection: HomeAssistantConnection?

    private let store = NSUbiquitousKeyValueStore.default
    /// Held so the block observer can be removed when this instance dies —
    /// the owning card is recreated on every dashboard visit, so without
    /// removal each visit would leak one more registered block.
    /// nonisolated(unsafe): written once in init, read once in deinit
    /// (which is nonisolated) — no concurrent access is possible.
    /// @ObservationIgnored keeps it raw storage the attribute can apply to.
    @ObservationIgnored private nonisolated(unsafe) var kvsObserver: NSObjectProtocol?

    // MARK: Wire format

    private struct Payload: Codable {
        var connection: HomeAssistantConnection?
        var deletedAt: Date?
    }

    // MARK: Lifecycle

    /// init stays CHEAP (a UserDefaults decode): as a @State default value
    /// this runs on every re-creation of the host view struct, and SwiftUI
    /// throws all but the first instance away.
    init() {
        loadLocal()
    }

    deinit {
        if let kvsObserver { NotificationCenter.default.removeObserver(kvsObserver) }
    }

    /// One-time KVS hookup, called from the owning view's .task — only the
    /// instance SwiftUI actually kept ever registers and reconciles.
    func activate() {
        guard kvsObserver == nil else { return }
        kvsObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        store.synchronize()
        reconcile()
    }

    var isConnected: Bool { connection != nil }

    // MARK: Mutations

    /// Save (or replace) the connection. A non-nil `token` (re)writes the
    /// Keychain; passing nil on an edit leaves the stored token untouched. The
    /// existing pinned-entity picks carry over across an edit.
    func save(urlString: String, token: String?) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespaces)
        let old = connection
        let record = HomeAssistantConnection(
            urlString: trimmedURL,
            pinnedEntities: old?.pinnedEntities ?? [],
            updatedAt: Date()
        )
        // If the address changed, retire the old token so a stale secret isn't
        // left stranded under the previous account key.
        if let old, old.credentialAccount != record.credentialAccount {
            SyncedKeychain.delete(service: Self.keychainService, account: old.credentialAccount)
        }
        connection = record
        if let token, !token.isEmpty {
            SyncedKeychain.set(token, service: Self.keychainService, account: record.credentialAccount)
        }
        persistLocal()
        pushLocal(deletedAt: nil)
    }

    /// Update which entities the card shows (from the entity picker).
    func setPinnedEntities(_ ids: [String]) {
        guard var record = connection else { return }
        record.pinnedEntities = ids
        record.updatedAt = Date()
        connection = record
        persistLocal()
        pushLocal(deletedAt: nil)
    }

    func disconnect() {
        if let account = connection?.credentialAccount {
            SyncedKeychain.delete(service: Self.keychainService, account: account)
        }
        connection = nil
        persistLocal()
        pushLocal(deletedAt: Date())
    }

    func token() -> String {
        guard let account = connection?.credentialAccount else { return "" }
        return SyncedKeychain.read(service: Self.keychainService, account: account) ?? ""
    }

    /// A ready-to-use client for the saved connection, or nil if unusable.
    func client() -> HomeAssistantClient? {
        guard let url = connection?.url else { return nil }
        let token = token()
        guard !token.isEmpty else { return nil }
        return HomeAssistantClient(baseURL: url, token: token)
    }

    /// A client from unsaved form values — used to test before committing.
    func trialClient(urlString: String, token: String) -> HomeAssistantClient? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil, url.host != nil, !token.isEmpty else { return nil }
        return HomeAssistantClient(baseURL: url, token: token)
    }

    // MARK: Sync

    /// Merge the local record and the remote payload, newest-write-wins across
    /// the connection's `updatedAt` and the tombstone's `deletedAt`.
    private func reconcile() {
        let payload = remotePayload()
        let localStamp = connection?.updatedAt ?? .distantPast
        let remoteConnStamp = payload.connection?.updatedAt ?? .distantPast
        let remoteDeleteStamp = payload.deletedAt ?? .distantPast

        // The most recent event across all three sources decides the state.
        let newest = max(localStamp, remoteConnStamp, remoteDeleteStamp)

        if newest == remoteDeleteStamp && remoteDeleteStamp > localStamp {
            // A newer disconnect from another device — drop the local copy.
            if connection != nil {
                if let account = connection?.credentialAccount {
                    SyncedKeychain.delete(service: Self.keychainService, account: account)
                }
                connection = nil
                persistLocal()
            }
        } else if remoteConnStamp > localStamp, let remote = payload.connection {
            // A newer connection from another device — adopt it (the token arrives
            // over the synced Keychain independently).
            connection = remote
            persistLocal()
        } else if localStamp > max(remoteConnStamp, remoteDeleteStamp) {
            // We're ahead — push local up.
            pushLocal(deletedAt: nil)
        }
    }

    private func pushLocal(deletedAt: Date?) {
        var payload = Payload()
        payload.connection = connection
        if let deletedAt {
            payload.deletedAt = deletedAt
        } else {
            // Preserve any prior tombstone only if it's still newer than this
            // write; otherwise a live connection supersedes it.
            let prior = remotePayload().deletedAt ?? .distantPast
            let stamp = connection?.updatedAt ?? .distantPast
            payload.deletedAt = prior > stamp ? prior : nil
        }
        writePayload(payload)
    }

    private func remotePayload() -> Payload {
        guard let data = store.data(forKey: Self.syncKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Payload()
        }
        return payload
    }

    private func writePayload(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        store.set(data, forKey: Self.syncKey)
        store.synchronize()
    }

    // MARK: Local cache

    private func loadLocal() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(HomeAssistantConnection.self, from: data) else { return }
        connection = decoded
    }

    private func persistLocal() {
        if let connection, let data = try? JSONEncoder().encode(connection) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
    }
}
