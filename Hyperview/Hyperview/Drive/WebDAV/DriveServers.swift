//
//  DriveServers.swift
//  Unifyr
//
//  The saved WebDAV connections shown under "Servers" in the Drive sidebar. The
//  config (name, URL, username) persists in UserDefaults; the password rides the
//  synced iCloud Keychain — the same store the mail passwords use — so a server
//  added on the iPhone brings its password to the Mac without retyping.
//
//  The Keychain account is keyed by IDENTITY (username + URL), not by the row's
//  UUID, so the synced password is useful across devices even before the config
//  list itself syncs (the same lesson the mail-account UUID work taught us).
//

import Foundation

/// One saved WebDAV server. Codable for UserDefaults; Hashable so it can drive
/// navigation and `.task(id:)`.
nonisolated struct DriveServer: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var urlString: String
    var username: String

    init(id: UUID = UUID(), name: String, urlString: String, username: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.username = username
    }

    var url: URL? { URL(string: urlString) }

    /// The row's display name, falling back to the URL's host if left blank.
    var title: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return url?.host ?? urlString
    }

    /// Stable Keychain account: the same server on two devices resolves to the
    /// same secret regardless of each device's row UUID.
    var credentialAccount: String { "\(username)@\(urlString)" }
}

@MainActor
@Observable
final class DriveServers {
    private static let defaultsKey = "drive.servers"
    private static let keychainService = "com.mcgraw.Hyperview.webdav"

    private(set) var servers: [DriveServer] = []

    init() {
        load()
    }

    func server(_ id: UUID) -> DriveServer? {
        servers.first { $0.id == id }
    }

    /// Add or update a server. Passing a `password` (re)writes the Keychain; a nil
    /// password on an edit leaves the stored secret untouched.
    @discardableResult
    func save(_ server: DriveServer, password: String?) -> DriveServer {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if let password {
            SyncedKeychain.set(password, service: Self.keychainService, account: server.credentialAccount)
        }
        persist()
        return server
    }

    func remove(_ server: DriveServer) {
        servers.removeAll { $0.id == server.id }
        SyncedKeychain.delete(service: Self.keychainService, account: server.credentialAccount)
        persist()
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

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([DriveServer].self, from: data) else { return }
        servers = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
