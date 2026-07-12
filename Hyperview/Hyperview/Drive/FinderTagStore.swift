//
//  FinderTagStore.swift
//  Hyperview
//
//  The user's full Finder tag vocabulary for the Drive module. macOS has no
//  single public "list all tags" call, so this unions the reliable sources:
//    • the 7 standard color tags (always available),
//    • the user's Favorite Tags from com.apple.finder prefs (includes custom
//      ones like "taxes"; read at the REAL home — works when Full Disk Access
//      is granted, which Hyperview already uses for Messages),
//    • every tag actually applied to files across the added Drive locations,
//    • any tag the user creates from Hyperview (persisted).
//  Finder tags are just strings written via .tagNamesKey, so a new name here
//  becomes a real system-wide tag the moment it's applied to a file.
//

import Foundation

@MainActor
@Observable
final class FinderTagStore {
    /// Finder's built-in color tags, in canonical order.
    static let standardColors = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
    private static let customKey = "drive.customFinderTags"

    private(set) var allTags: [String] = FinderTagStore.standardColors

    /// Rebuild the vocabulary. Scanning runs off the main actor.
    func refresh(locations: [URL]) {
        let roots = locations
        Task.detached(priority: .utility) {
            let favorites = Self.favoriteTags()
            let scanned = Self.scanTags(in: roots)
            await MainActor.run { self.combine(favorites: favorites, scanned: scanned) }
        }
    }

    /// Add a user-created tag name to the vocabulary (persisted).
    func addCustom(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var stored = UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []
        if !stored.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            stored.append(trimmed)
            UserDefaults.standard.set(stored, forKey: Self.customKey)
        }
        if !allTags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            allTags = orderedList(Set(allTags).union([trimmed]))
        }
    }

    // MARK: - Assembly

    private func combine(favorites: [String], scanned: Set<String>) {
        var set = Set(Self.standardColors)
        set.formUnion(favorites)
        set.formUnion(scanned)
        set.formUnion(UserDefaults.standard.stringArray(forKey: Self.customKey) ?? [])
        set.remove("")
        allTags = orderedList(set)
    }

    /// Standard colors first (canonical order), then custom names A→Z.
    private func orderedList(_ set: Set<String>) -> [String] {
        let colors = Self.standardColors.filter { set.contains($0) }
        let customs = set.subtracting(Self.standardColors)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return colors + customs
    }

    // MARK: - Sources (nonisolated: run off main)

    private nonisolated static func realHome() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// Favorite tag names from com.apple.finder (real-home plist; needs FDA).
    private nonisolated static func favoriteTags() -> [String] {
        let url = URL(fileURLWithPath: realHome() + "/Library/Preferences/com.apple.finder.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let favorites = plist["FavoriteTagNames"] as? [String] else {
            return []
        }
        return favorites.filter { !$0.isEmpty }
    }

    /// Union of Finder tags applied to files across the added locations
    /// (bounded per location so a huge tree can't stall the scan).
    private nonisolated static func scanTags(in roots: [URL]) -> Set<String> {
        var result = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.tagNamesKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var scanned = 0
            while let url = enumerator.nextObject() as? URL {
                scanned += 1
                if scanned > 8000 { break }
                if let values = try? url.resourceValues(forKeys: [.tagNamesKey]),
                   let names = values.tagNames {
                    result.formUnion(names)
                }
            }
        }
        return result
    }
}
