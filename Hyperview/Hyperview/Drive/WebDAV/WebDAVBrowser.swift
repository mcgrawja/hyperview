//
//  WebDAVBrowser.swift
//  Unifyr
//
//  Browses one WebDAV server. Self-contained: it lists a folder over the network,
//  drills into subfolders, and downloads a tapped file to a temp location so the
//  existing preview / share path can show it. It deliberately does NOT reuse the
//  local `DriveFileList` (that one is bound to `file://` URLs and FileManager) —
//  a server listing is remote, lazy, and read-only here.
//
//  Navigation is handed back to DriveView so each layout routes it natively:
//  the phone pushes a screen per folder, the Mac/iPad drives the middle pane.
//

import SwiftUI

/// Where in a server we are: which server, and which folder URL (nil = its root).
/// Hashable so it works as a navigation value and a `.task(id:)`.
nonisolated struct WebDAVLocation: Hashable {
    let serverID: UUID
    let url: URL?
}

/// Sorting for a remote listing — mirrors `DriveSort` but over `WebDAVEntry`.
private nonisolated enum WebDAVSort {
    static func apply(_ items: [WebDAVEntry], field: DriveSortField, ascending: Bool) -> [WebDAVEntry] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch compare(lhs, rhs, by: field) {
            case .orderedAscending: return ascending
            case .orderedDescending: return !ascending
            case .orderedSame:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private static func compare(_ lhs: WebDAVEntry, _ rhs: WebDAVEntry, by field: DriveSortField) -> ComparisonResult {
        switch field {
        case .name: return lhs.name.localizedStandardCompare(rhs.name)
        case .kind: return lhs.kind.localizedStandardCompare(rhs.kind)
        case .modified: return order(lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
        case .size: return order(lhs.size ?? -1, rhs.size ?? -1)
        }
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

struct WebDAVBrowser: View {
    let server: DriveServer
    let location: WebDAVLocation
    let servers: DriveServers
    /// Descend into a subfolder (DriveView routes it per layout).
    let onOpenFolder: (WebDAVLocation) -> Void
    /// A file finished downloading to this temp URL — show/share it.
    let onOpenFile: (URL) -> Void

    @Environment(\.isCompactLayout) private var isCompact
    @State private var entries: [WebDAVEntry] = []
    @State private var loading = false
    @State private var errorText: String?
    /// The entry currently downloading, so its row shows a spinner.
    @State private var downloadingID: URL?
    @AppStorage("drive.sortField") private var sortField: DriveSortField = .name
    @AppStorage("drive.sortAscending") private var sortAscending = true

    private var targetURL: URL? { location.url ?? server.url }

    private var sortedEntries: [WebDAVEntry] {
        WebDAVSort.apply(entries, field: sortField, ascending: sortAscending)
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider().overlay(Theme.Palette.separator)
            content
        }
        .background(Theme.Palette.background)
        .task(id: location) { await reload() }
        .toolbar {
            ToolbarItem { sortMenu }
            ToolbarItem {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let errorText {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(errorText)
                    .font(Theme.Font.cardBody)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await reload() } }
                    .buttonStyle(.bordered)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading && entries.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            EmptyStateLine(text: "Empty folder.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sortedEntries) { entry in
                    row(entry)
                        .contentShape(Rectangle())
                        .onTapGesture { open(entry) }
                }
            }
            .listStyle(.inset)
            .refreshable { await reload() }
        }
    }

    private func row(_ entry: WebDAVEntry) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            if downloadingID == entry.url {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            } else {
                Image(systemName: entry.symbolName)
                    .foregroundStyle(Theme.Palette.primary)
                    .frame(width: 18)
            }
            Text(entry.name)
                .font(Theme.Font.cardBody)
                .lineLimit(1)
            Spacer()
            if !entry.isDirectory, let size = entry.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 74, alignment: .trailing)
            }
            if let modified = entry.modified {
                Text(modified.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 140, alignment: .trailing)
            }
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(.vertical, 1)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortField) {
                ForEach(DriveSortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            Divider()
            Picker("Order", selection: $sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        } label: {
            Label("Sort", systemImage: sortAscending ? "arrow.up.arrow.down" : "arrow.down.arrow.up")
        }
        .help("Sort by \(sortField.title)")
    }

    // MARK: Breadcrumbs

    /// Crumbs from the server root down to the current folder. Tapping one jumps
    /// back up; the current (last) crumb is inert.
    private var breadcrumbs: some View {
        let crumbs = crumbTrail
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    let isLast = index == crumbs.count - 1
                    Button(crumb.title) {
                        if !isLast { onOpenFolder(WebDAVLocation(serverID: server.id, url: crumb.url)) }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Font.cardBody.weight(isLast ? .semibold : .regular))
                    .foregroundStyle(isLast ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .disabled(isLast)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }

    private var crumbTrail: [(title: String, url: URL?)] {
        var trail: [(title: String, url: URL?)] = [(server.title, nil)]
        guard let root = server.url, let target = targetURL else { return trail }
        // Build the trail DOWN from the root using path components — a loop
        // bounded by the component count. (Walking UP with
        // `deleteLastPathComponent()` and a path-length test can spin forever
        // when the root path's "/" vs "" representation differs across OS
        // versions — that hangs the folder screen on tap.)
        let rootComponents = root.pathComponents.filter { $0 != "/" }
        let targetComponents = target.pathComponents.filter { $0 != "/" }
        guard targetComponents.count > rootComponents.count else { return trail }
        var url = root
        for component in targetComponents[rootComponents.count...] {
            url = url.appendingPathComponent(component, isDirectory: true)
            trail.append((component, url))
        }
        return trail
    }

    // MARK: Actions

    private func open(_ entry: WebDAVEntry) {
        if entry.isDirectory {
            onOpenFolder(WebDAVLocation(serverID: server.id, url: entry.url))
        } else {
            Task { await download(entry) }
        }
    }

    private func reload() async {
        guard let client = servers.client(for: server) else {
            errorText = WebDAVError.badServerURL.errorDescription
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            entries = try await client.list(location.url)
        } catch {
            entries = []
            errorText = error.localizedDescription
        }
    }

    private func download(_ entry: WebDAVEntry) async {
        guard let client = servers.client(for: server) else { return }
        downloadingID = entry.url
        defer { downloadingID = nil }
        do {
            let local = try await client.download(entry.url)
            onOpenFile(local)
        } catch {
            errorText = "Couldn't download “\(entry.name)”: \(error.localizedDescription)"
        }
    }
}
