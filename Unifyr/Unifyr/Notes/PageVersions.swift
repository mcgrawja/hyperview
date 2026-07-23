//
//  PageVersions.swift
//  Unifyr
//
//  Round 5: page version history. Local, per-device snapshots of a document's
//  JSON (deliberately NOT CloudKit — history is a safety net, not synced
//  state, and it avoids a schema change). Files live under Application
//  Support/PageVersions/<docID>/<epoch>.json; throttled to one per 10 minutes,
//  pruned to the newest 30.
//
//  Keyed by DOCUMENT id — note pages and database row pages both get history.
//

import Foundation
import SwiftUI
import SwiftData

enum PageVersions {
    private static let throttle: TimeInterval = 10 * 60
    private static let keep = 30

    private static func directory(for docID: UUID) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "PageVersions")
            .appending(path: docID.uuidString)
    }

    /// Record a snapshot unless one landed within the throttle window or the
    /// content is byte-identical to the newest.
    static func maybeSnapshot(docID: UUID, data: Data) {
        guard !data.isEmpty else { return }
        let dir = directory(for: docID)
        let existing = list(docID: docID)
        if let newest = existing.first {
            if Date().timeIntervalSince(newest.date) < throttle { return }
            if (try? Data(contentsOf: newest.url)) == data { return }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: url)
        for stale in list(docID: docID).dropFirst(keep) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    /// First-load baseline so a page's pre-edit state is always restorable.
    static func baseline(docID: UUID, data: Data) {
        guard list(docID: docID).isEmpty else { return }
        maybeSnapshot(docID: docID, data: data)
    }

    /// Snapshots, newest first.
    static func list(docID: UUID) -> [(date: Date, url: URL)] {
        let dir = directory(for: docID)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .compactMap { url -> (Date, URL)? in
                guard let epoch = TimeInterval(url.deletingPathExtension().lastPathComponent) else { return nil }
                return (Date(timeIntervalSince1970: epoch), url)
            }
            .sorted { $0.0 > $1.0 }
            .map { (date: $0.0, url: $0.1) }
    }
}

/// The Version History sheet: snapshots with previews; Restore replaces the
/// page's content (the current state is snapshotted first, so restoring is
/// itself undoable).
struct VersionHistorySheet: View {
    let note: Note

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var versions: [(date: Date, url: URL)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Version History")
                .font(Theme.Font.cardTitle)
                .padding(Theme.Spacing.lg)

            Divider().overlay(Theme.Palette.separator)

            if versions.isEmpty {
                EmptyStateLine(text: "No snapshots yet — versions record as you edit (about every 10 minutes).")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(versions, id: \.url) { version in
                    HStack(spacing: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(version.date.formatted(date: .abbreviated, time: .shortened))
                                .font(Theme.Font.cardBody)
                            Text(preview(version.url))
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Restore") { restore(version.url) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, Theme.Spacing.xxs)
                }
                .listStyle(.plain)
            }

            Divider().overlay(Theme.Palette.separator)
            HStack {
                Text("Versions are stored on this device only.")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(minWidth: 460, minHeight: 380)
        .background(Theme.Palette.background)
        .onAppear { versions = PageVersions.list(docID: note.id) }
    }

    private func preview(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let text = EditorIntegrations.plainText(of: BlockSerializer.decodeDocument(data))
            .replacingOccurrences(of: "\n", with: " · ")
        return String(text.prefix(140))
    }

    private func restore(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let store = NotesStore(context: context)
        // Snapshot the CURRENT state first — restoring must never lose it.
        PageVersions.maybeSnapshot(
            docID: note.id,
            data: BlockSerializer.encode(store.loadDocument(note))
        )
        store.save(BlockSerializer.decodeDocument(data), to: note)
        try? context.save()
        NotificationCenter.default.post(name: .unifyrReloadEditor, object: nil)
        dismiss()
    }
}
