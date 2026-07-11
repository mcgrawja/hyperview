//
//  DriveLocations.swift
//  Hyperview
//
//  The Drive module's roots. The app is sandboxed, so it can only browse
//  folders the user explicitly adds (NSOpenPanel). Each grant is persisted as
//  a security-scoped bookmark and re-resolved at launch, so locations survive
//  restarts like Finder sidebar favorites.
//

import Foundation
import AppKit

@MainActor
@Observable
final class DriveLocations {
    private static let key = "drive.locationBookmarks"

    private(set) var roots: [URL] = []

    init() {
        restore()
    }

    /// Ask the user for a folder and remember it.
    func addLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to browse in Hyperview"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            add(url)
        }
    }

    func add(_ url: URL) {
        guard !roots.contains(url) else { return }
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        var bookmarks = (UserDefaults.standard.array(forKey: Self.key) as? [Data]) ?? []
        bookmarks.append(bookmark)
        UserDefaults.standard.set(bookmarks, forKey: Self.key)
        _ = url.startAccessingSecurityScopedResource()
        roots.append(url)
    }

    func remove(_ url: URL) {
        guard let index = roots.firstIndex(of: url) else { return }
        roots.remove(at: index)
        url.stopAccessingSecurityScopedResource()
        // Rebuild the persisted list from the still-valid roots.
        let bookmarks = roots.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.key)
    }

    private func restore() {
        let bookmarks = (UserDefaults.standard.array(forKey: Self.key) as? [Data]) ?? []
        var resolved: [URL] = []
        var validBookmarks: [Data] = []
        for data in bookmarks {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            resolved.append(url)
            if stale, let fresh = try? url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            ) {
                validBookmarks.append(fresh)
            } else {
                validBookmarks.append(data)
            }
        }
        roots = resolved
        if validBookmarks.count != bookmarks.count {
            UserDefaults.standard.set(validBookmarks, forKey: Self.key)
        }
    }
}
