//
//  TagsStore.swift
//  Hyperview
//
//  App-level window onto the universal tags for consumers that live OUTSIDE
//  the main CloudKit container's view subtree — chiefly the Mail module,
//  whose subtree overrides \.modelContext with the mail cache container.
//  Owns its own ModelContext on the main container; refreshes itself whenever
//  any tag UI posts .hyperviewTagsChanged.
//
//  Also hosts the one-time migration of Mail's old MailTag/MailTagAssignment
//  data into HVTag/HVTagLink (kind "mail", keyed by Message-ID header).
//

import Foundation
import SwiftData

extension Notification.Name {
    /// Posted after any tag mutation so cross-container consumers refresh.
    static let hyperviewTagsChanged = Notification.Name("hyperview.tagsChanged")
}

nonisolated struct TagInfo: Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var colorHex: String
}

@MainActor
@Observable
final class TagsStore {
    private let context: ModelContext
    private(set) var tags: [TagInfo] = []
    /// itemKind → itemKey → tag ids.
    private var links: [String: [String: Set<UUID>]] = [:]
    // Only handed to removeObserver; safe to share.
    @ObservationIgnored nonisolated(unsafe) private var changeToken: (any NSObjectProtocol)?

    init(container: ModelContainer) {
        context = ModelContext(container)
        refresh()
        changeToken = NotificationCenter.default.addObserver(
            forName: .hyperviewTagsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let changeToken {
            NotificationCenter.default.removeObserver(changeToken)
        }
    }

    func refresh() {
        let allTags = (try? context.fetch(FetchDescriptor<HVTag>())) ?? []
        tags = allTags
            .map { TagInfo(id: $0.id, name: $0.name, colorHex: $0.colorHex) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var map: [String: [String: Set<UUID>]] = [:]
        for link in (try? context.fetch(FetchDescriptor<HVTagLink>())) ?? [] {
            guard let tagID = link.tagID else { continue }
            map[link.itemKind, default: [:]][link.itemKey, default: []].insert(tagID)
        }
        links = map
    }

    // MARK: Reads

    func isTagged(_ tagID: UUID, kind: String, key: String) -> Bool {
        links[kind]?[key]?.contains(tagID) ?? false
    }

    func tags(kind: String, key: String) -> [TagInfo] {
        let ids = links[kind]?[key] ?? []
        return tags.filter { ids.contains($0.id) }
    }

    func keys(with tagID: UUID, kind: String) -> Set<String> {
        var result = Set<String>()
        for (key, ids) in links[kind] ?? [:] where ids.contains(tagID) {
            result.insert(key)
        }
        return result
    }

    func count(_ tagID: UUID, kind: String) -> Int {
        keys(with: tagID, kind: kind).count
    }

    // MARK: Writes

    func toggle(_ tagID: UUID, kind: String, key: String) {
        if isTagged(tagID, kind: kind, key: key) {
            let all = (try? context.fetch(FetchDescriptor<HVTagLink>())) ?? []
            for link in all where link.tagID == tagID && link.itemKind == kind && link.itemKey == key {
                context.delete(link)
            }
        } else {
            context.insert(HVTagLink(tagID: tagID, itemKind: kind, itemKey: key))
        }
        try? context.save()
        NotificationCenter.default.post(name: .hyperviewTagsChanged, object: nil)
    }

    /// Idempotent link (rules use this: tag on arrival, never untag).
    func link(_ tagID: UUID, kind: String, key: String) {
        guard !isTagged(tagID, kind: kind, key: key) else { return }
        context.insert(HVTagLink(tagID: tagID, itemKind: kind, itemKey: key))
        try? context.save()
        NotificationCenter.default.post(name: .hyperviewTagsChanged, object: nil)
    }

    // MARK: - Mail tag migration

    /// One-time: MailTag/MailTagAssignment (mail-local store) → HVTag/HVTagLink
    /// (CloudKit store), merging by name and remapping rule actions. The old
    /// rows are left in place (harmless, unused).
    static func migrateMailTagsIfNeeded(mailContainer: ModelContainer, mainContainer: ModelContainer) {
        let flag = "tags.unifiedMailMigrated"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let mailContext = mailContainer.mainContext
        let mainContext = mainContainer.mainContext

        let mailTags = (try? mailContext.fetch(FetchDescriptor<MailTag>())) ?? []
        let existing = (try? mainContext.fetch(FetchDescriptor<HVTag>())) ?? []
        var byName: [String: HVTag] = [:]
        for tag in existing { byName[tag.name.lowercased()] = tag }

        var idMap: [UUID: UUID] = [:]
        for mailTag in mailTags {
            if let match = byName[mailTag.name.lowercased()] {
                idMap[mailTag.id] = match.id
            } else {
                let created = HVTag(name: mailTag.name, colorHex: mailTag.colorHex)
                mainContext.insert(created)
                byName[created.name.lowercased()] = created
                idMap[mailTag.id] = created.id
            }
        }

        let assignments = (try? mailContext.fetch(FetchDescriptor<MailTagAssignment>())) ?? []
        let existingLinks = (try? mainContext.fetch(FetchDescriptor<HVTagLink>())) ?? []
        var seen = Set(existingLinks.map { "\($0.tagID?.uuidString ?? "")|\($0.itemKind)|\($0.itemKey)" })
        for assignment in assignments {
            guard let newID = idMap[assignment.tagID] else { continue }
            let dedupeKey = "\(newID.uuidString)|\(TagKind.mail)|\(assignment.messageIDHeader)"
            guard !seen.contains(dedupeKey) else { continue }
            seen.insert(dedupeKey)
            mainContext.insert(HVTagLink(tagID: newID, itemKind: TagKind.mail, itemKey: assignment.messageIDHeader))
        }

        // Rules that add a MailTag now add the corresponding universal tag.
        let rules = (try? mailContext.fetch(FetchDescriptor<MailRule>())) ?? []
        for rule in rules {
            var action = rule.action
            if let old = action.addTagID, let new = idMap[old] {
                action.addTagID = new
                rule.action = action
            }
        }

        try? mainContext.save()
        try? mailContext.save()
        UserDefaults.standard.set(true, forKey: flag)
        if !mailTags.isEmpty {
            MailLog.log("[Tags] migrated \(mailTags.count) mail tags + \(assignments.count) assignments to universal tags")
        }
    }
}
