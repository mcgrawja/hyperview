//
//  DriveServers.swift
//  Unifyr
//
//  The saved WebDAV connections shown under "Servers" in the Drive sidebar. The
//  config (name, URL, username) syncs across devices via iCloud's key-value
//  store — the same transport the mail accounts use (see MailAccountSync) — so a
//  server added on the iPhone appears on the Mac. The password rides the synced
//  iCloud Keychain separately.
//
//  Identity is the credential account (username + URL), NOT the row's UUID:
//  that's what the Keychain password keys off, so two devices converge on one
//  entry even though each minted its own UUID. Conflicts resolve last-write-wins
//  on `updatedAt`; deletions leave tombstones so a removed server isn't
//  resurrected by another device's copy.
//

import Foundation

/// One saved WebDAV server. Codable for both the local cache and the iCloud
/// key-value payload; Hashable so it can drive navigation and `.task(id:)`.
nonisolated struct DriveServer: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var urlString: String
    var username: String
    /// Last local edit — the last-write-wins key for cross-device merge.
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, urlString: String, username: String, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.username = username
        self.updatedAt = updatedAt
    }

    /// Legacy rows (saved before sync existed) have no `updatedAt`; default it to
    /// the distant past so any real synced copy wins, and so it still propagates.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        urlString = try c.decode(String.self, forKey: .urlString)
        username = try c.decode(String.self, forKey: .username)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    var url: URL? { URL(string: urlString) }

    /// The row's display name, falling back to the URL's host if left blank.
    var title: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return url?.host ?? urlString
    }

    /// Stable identity across devices: same server → same secret and same merge
    /// key, regardless of each device's row UUID.
    var credentialAccount: String { "\(username)@\(urlString)" }
}

@MainActor
@Observable
final class DriveServers {
    private static let defaultsKey = "drive.servers"
    private static let syncKey = "drive.servers.v1"
    private static let keychainService = "com.mcgraw.Hyperview.webdav"

    private(set) var servers: [DriveServer] = []

    private let store = NSUbiquitousKeyValueStore.default
    /// Held so the block observer can be removed if this instance is ever
    /// recreated (DriveView holds it as @State, which SwiftUI can rebuild).
    /// nonisolated(unsafe): written once in init, read once in deinit — no
    /// concurrent access is possible.
    /// @ObservationIgnored keeps it raw storage the attribute can apply to.
    @ObservationIgnored private nonisolated(unsafe) var kvsObserver: NSObjectProtocol?

    // MARK: Wire format

    private struct Payload: Codable {
        var servers: [DriveServer] = []
        var tombstones: [Tombstone] = []
    }

    private struct Tombstone: Codable {
        var account: String     // credentialAccount
        var deletedAt: Date
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

    /// One-time KVS hookup (re-reconcile whenever another device writes),
    /// called from the owning view's .task — only the instance SwiftUI kept
    /// ever registers and reconciles.
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

    func server(_ id: UUID) -> DriveServer? {
        servers.first { $0.id == id }
    }

    // MARK: Mutations

    /// Add or update a server. Passing a `password` (re)writes the Keychain; a nil
    /// password on an edit leaves the stored secret untouched.
    @discardableResult
    func save(_ server: DriveServer, password: String?) -> DriveServer {
        var stamped = server
        stamped.updatedAt = Date()
        if let index = servers.firstIndex(where: { $0.id == stamped.id }) {
            let old = servers[index]
            // If the URL/username changed, the identity key changed too. Retire
            // the old identity (Keychain + tombstone) so another device doesn't
            // resurrect it from the synced payload as a duplicate.
            if old.credentialAccount != stamped.credentialAccount {
                SyncedKeychain.delete(service: Self.keychainService, account: old.credentialAccount)
                writeTombstone(account: old.credentialAccount)
            }
            servers[index] = stamped
        } else {
            servers.append(stamped)
        }
        if let password {
            SyncedKeychain.set(password, service: Self.keychainService, account: stamped.credentialAccount)
        }
        persistLocal()
        reconcile()
        return stamped
    }

    func remove(_ server: DriveServer) {
        servers.removeAll { $0.id == server.id }
        SyncedKeychain.delete(service: Self.keychainService, account: server.credentialAccount)
        persistLocal()
        writeTombstone(account: server.credentialAccount)
        reconcile()
    }

    /// Record a deletion of an identity so other devices drop it instead of
    /// pushing it back at us on their next sync.
    private func writeTombstone(account: String) {
        var payload = remotePayload()
        payload.servers.removeAll { $0.credentialAccount == account }
        payload.tombstones.removeAll { $0.account == account }
        payload.tombstones.append(Tombstone(account: account, deletedAt: Date()))
        writePayload(payload)
    }

    func password(for server: DriveServer) -> String {
        SyncedKeychain.read(service: Self.keychainService, account: server.credentialAccount) ?? ""
    }

    /// A ready-to-use client for a saved server, or nil if its URL is malformed.
    func client(for server: DriveServer) -> WebDAVClient? {
        guard let url = server.url else { return nil }
        return WebDAVClient(baseURL: url, username: server.username, password: password(for: server))
    }

    /// A client from unsaved form values — used to test a connection before the
    /// server is committed to the list.
    func trialClient(urlString: String, username: String, password: String) -> WebDAVClient? {
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else { return nil }
        return WebDAVClient(baseURL: url, username: username, password: password)
    }

    // MARK: Sync

    /// Merge remote into local and local into remote so the two converge no
    /// matter which device saw the change first. Keyed by `credentialAccount`.
    private func reconcile() {
        var payload = remotePayload()
        var localByAccount: [String: DriveServer] = [:]
        for server in servers { localByAccount[server.credentialAccount] = server }

        var localChanged = false
        var remoteChanged = false

        // 1. Deletions from another device — unless we've edited since, or it was
        //    re-added there after the deletion.
        for tombstone in payload.tombstones {
            let readdedSince = payload.servers.contains {
                $0.credentialAccount == tombstone.account && $0.updatedAt > tombstone.deletedAt
            }
            guard !readdedSince else { continue }
            if let local = localByAccount[tombstone.account], local.updatedAt <= tombstone.deletedAt {
                localByAccount[tombstone.account] = nil
                localChanged = true
            }
        }

        // 2. Remote servers land (or update) locally, unless a later tombstone.
        for record in payload.servers {
            let deletedLater = payload.tombstones.contains {
                $0.account == record.credentialAccount && $0.deletedAt > record.updatedAt
            }
            if deletedLater { continue }
            if let local = localByAccount[record.credentialAccount] {
                if record.updatedAt > local.updatedAt {
                    localByAccount[record.credentialAccount] = record
                    localChanged = true
                }
            } else {
                localByAccount[record.credentialAccount] = record
                localChanged = true
            }
        }

        // 3. Local servers (new, or edited newer than the remote copy) go up, and
        //    a live server clears any stale tombstone so it isn't purged next pass.
        for local in localByAccount.values {
            if let index = payload.servers.firstIndex(where: { $0.credentialAccount == local.credentialAccount }) {
                if local.updatedAt > payload.servers[index].updatedAt {
                    payload.servers[index] = local
                    remoteChanged = true
                }
            } else {
                payload.servers.append(local)
                remoteChanged = true
            }
            if payload.tombstones.contains(where: { $0.account == local.credentialAccount && $0.deletedAt < local.updatedAt }) {
                payload.tombstones.removeAll { $0.account == local.credentialAccount && $0.deletedAt < local.updatedAt }
                remoteChanged = true
            }
        }

        // Drop remote records a later tombstone has superseded, so the payload
        // doesn't grow unbounded.
        let prunedCount = payload.servers.count
        payload.servers.removeAll { record in
            payload.tombstones.contains { $0.account == record.credentialAccount && $0.deletedAt > record.updatedAt }
        }
        if payload.servers.count != prunedCount { remoteChanged = true }

        if localChanged {
            servers = localByAccount.values.sorted {
                let byTitle = $0.title.localizedCaseInsensitiveCompare($1.title)
                return byTitle == .orderedSame ? $0.urlString < $1.urlString : byTitle == .orderedAscending
            }
            persistLocal()
        }
        if remoteChanged { writePayload(payload) }
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
              let decoded = try? JSONDecoder().decode([DriveServer].self, from: data) else { return }
        servers = decoded
    }

    private func persistLocal() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
