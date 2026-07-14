//
//  DriveLocations.swift
//  Unifyr
//
//  The Drive module's roots. The app is sandboxed on both platforms, so it can
//  only browse folders the user explicitly adds — NSOpenPanel on macOS, the
//  document picker (`.fileImporter`) on iOS. Each grant is persisted as a
//  bookmark and re-resolved at launch, so locations survive restarts like
//  Finder sidebar favorites.
//
//  The bookmark options differ per platform (same split as `FileLinkBookmarks`
//  in the notes editor): macOS needs `.withSecurityScope`, iOS bookmarks the
//  picked URL plainly and starts access on the resolved one.
//

import Foundation

@MainActor
@Observable
final class DriveLocations {
    private static let key = "drive.locationBookmarks"

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    private(set) var roots: [URL] = []

    init() {
        restore()
    }

    /// Ask the user for a folder and remember it. macOS runs the open panel
    /// inline; on iOS there is no such panel, so DriveView presents
    /// `.fileImporter` and calls `add(_:)` with what comes back.
    func addLocation() {
        guard let urls = PlatformKit.pickFolders(
            message: "Choose folders to browse in Unifyr",
            prompt: "Add"
        ) else { return }
        for url in urls {
            add(url)
        }
    }

    func add(_ url: URL) {
        guard !roots.contains(url) else { return }
        guard let bookmark = try? url.bookmarkData(
            options: Self.creationOptions,
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
            try? $0.bookmarkData(
                options: Self.creationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
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
                options: Self.resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            resolved.append(url)
            if stale, let fresh = try? url.bookmarkData(
                options: Self.creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil
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
