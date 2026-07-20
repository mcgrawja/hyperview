//
//  DriveView.swift
//  Unifyr
//
//  Finder-lite file manager: user-added locations in a sidebar (security-
//  scoped, persistent), breadcrumb navigation, a sortable file list with
//  icons/kind/size/date, and the everyday Finder verbs — open, reveal, rename,
//  new folder, duplicate, move to trash.
//
//  Both platforms. Mac and iPad get the desktop layout (locations | files |
//  preview); the iPhone is compact, so it PUSHES one screen at a time
//  (locations → folder → file preview) — PlatformHSplit would trap there.
//
//  Finder tags stay macOS-only: `URLResourceKey.tagNames` simply doesn't exist
//  on iOS, and the app's universal tags are deliberately NOT substituted here
//  (owner decision — see removeUniversalFileLinksIfNeeded).
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - Sorting

/// The column the file list sorts by. Raw value is what @AppStorage persists.
nonisolated enum DriveSortField: String, CaseIterable, Identifiable {
    case name
    case kind
    case modified
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .size: return "Size"
        }
    }
}

/// The list's ordering rule. Directories ALWAYS group first (Finder does this
/// regardless of the sort column and direction); the chosen field orders each
/// group, with the name as a stable tie-break.
nonisolated enum DriveSort {
    static func apply(_ items: [DriveItem], field: DriveSortField, ascending: Bool) -> [DriveItem] {
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

    private static func compare(_ lhs: DriveItem, _ rhs: DriveItem, by field: DriveSortField) -> ComparisonResult {
        switch field {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .kind:
            return lhs.kind.localizedStandardCompare(rhs.kind)
        case .modified:
            return order(lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
        case .size:
            // Folders report no size; -1 keeps them ordered among themselves.
            return order(lhs.size ?? -1, rhs.size ?? -1)
        }
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

/// One screen on the iPhone's navigation stack. A single Hashable type keeps
/// the stack's path homogeneous ([DriveRoute]) with one destination handler.
nonisolated enum DriveRoute: Hashable {
    case folder(URL)
    case file(URL)
    /// A WebDAV server folder (nil url = the server's root).
    case server(WebDAVLocation)
}

// MARK: - Module root

struct DriveView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.isCompactLayout) private var isCompact
    @State private var locations = DriveLocations()
    @State private var servers = DriveServers()
    /// Regular layout only — the folder the middle pane is showing.
    @State private var currentFolder: URL?
    /// Regular layout only — the WebDAV location the middle pane is showing.
    @State private var currentServer: WebDAVLocation?
    /// Compact layout only — the pushed screens.
    @State private var path: [DriveRoute] = []
    @State private var selection: URL?
    /// iOS folder picker (macOS uses NSOpenPanel via DriveLocations).
    @State private var addingLocation = false
    /// The "Connect to Server" sheet, and the server it's editing (nil = new).
    @State private var connectingServer = false
    @State private var editingServer: DriveServer?
    @AppStorage("drive.showPreview") private var showPreview = true
    @AppStorage("drive.previewWidth") private var previewWidth = 300.0
    @State private var previewDragBase: Double?

    var body: some View {
        Group {
            if isCompact {
                compactPanes
            } else {
                regularPanes
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Drive")
        .task {
            servers.activate()   // one-time KVS hookup (no-op after the first)
            removeUniversalFileLinksIfNeeded()
        }
    }

    // MARK: Panes

    /// Mac / iPad: locations + browser side by side. The preview is a SIBLING
    /// of the split (not a pane of it) so toggling it is instant, and its width
    /// comes from the drag handle rather than the splitter.
    private var regularPanes: some View {
        HStack(spacing: 0) {
            PlatformHSplit {
                locationsPane
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 280)
                middlePane
                    .frame(minWidth: 320)
            }
            if showPreview {
                previewResizeHandle
                Group {
                    if let selection {
                        DrivePreviewPane(item: DriveItem(url: selection)) {
                            open(DriveItem(url: selection))
                        }
                        .id(selection)
                    } else {
                        VStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "eye")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Text("Select a file to preview")
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.Palette.surface)
                    }
                }
                .frame(width: previewWidth)
            }
        }
    }

    /// iPhone: one screen at a time — locations → folder → file preview. Each
    /// pushed folder screen loads its OWN listing, so popping back reveals the
    /// parent's files with nothing stale in between.
    private var compactPanes: some View {
        NavigationStack(path: $path) {
            locationsPane
                .navigationTitle("Drive")
                .navigationDestination(for: DriveRoute.self) { route in
                    switch route {
                    case .folder(let folder):
                        DriveFileList(
                            folder: folder,
                            roots: locations.roots,
                            selection: $selection,
                            onOpen: open
                        )
                        .navigationTitle(folder.lastPathComponent)
                        .inlineNavigationTitle()
                    case .file(let file):
                        DrivePreviewPane(item: DriveItem(url: file)) {
                            PlatformKit.open(file)
                        }
                        .navigationTitle(file.lastPathComponent)
                        .inlineNavigationTitle()
                    case .server(let location):
                        if let server = servers.server(location.serverID) {
                            WebDAVBrowser(
                                server: server,
                                location: location,
                                servers: servers,
                                onOpenFolder: { path.append(.server($0)) },
                                onOpenFile: { path.append(.file($0)) }
                            )
                            .navigationTitle(location.url?.lastPathComponent ?? server.title)
                            .inlineNavigationTitle()
                        }
                    }
                }
        }
    }

    /// Thin draggable divider for the preview pane (drag left = wider).
    private var previewResizeHandle: some View {
        Rectangle()
            .fill(Theme.Palette.separator)
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = previewDragBase ?? previewWidth
                                previewDragBase = base
                                previewWidth = min(560, max(220, base - value.translation.width))
                            }
                            .onEnded { _ in previewDragBase = nil }
                    )
                    .platformResizeCursor()
            )
    }

    // MARK: Locations

    /// The locations list. It carries the module-level toolbar (Add Location,
    /// preview toggle) so those buttons land on the right bar on every layout:
    /// the window toolbar on Mac, the detail bar on iPad, and the root screen's
    /// bar inside the iPhone's navigation stack.
    private var locationsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LOCATIONS")
                .font(Theme.Font.cardCaption.weight(.semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(Theme.Spacing.md)
            if locations.roots.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("No locations yet.")
                        .font(Theme.Font.cardBody)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Button("Add Location…") { requestLocation() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Palette.primary)
                }
                .padding(Theme.Spacing.md)
            }
            List {
                ForEach(locations.roots, id: \.self) { root in
                    Button {
                        openLocation(root)
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Theme.Palette.primary)
                            Text(root.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        isInside(root) ? Theme.Palette.primary.softFill(0.12) : Color.clear
                    )
                    .contextMenu {
                        #if os(macOS)
                        Button("Reveal in Finder") {
                            PlatformKit.reveal(root)
                        }
                        #endif
                        Button("Remove from Drive", role: .destructive) {
                            removeLocation(root)
                        }
                    }
                }

                if !servers.servers.isEmpty {
                    Section("SERVERS") {
                        ForEach(servers.servers) { server in
                            Button {
                                openServer(server)
                            } label: {
                                HStack(spacing: Theme.Spacing.sm) {
                                    Image(systemName: "externaldrive.connected.to.line.below")
                                        .foregroundStyle(Theme.Palette.primary)
                                    Text(server.title)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                isServerActive(server) ? Theme.Palette.primary.softFill(0.12) : Color.clear
                            )
                            .contextMenu {
                                Button("Edit…") {
                                    editingServer = server
                                    connectingServer = true
                                }
                                Button("Remove from Drive", role: .destructive) {
                                    removeServer(server)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Theme.Palette.surface)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        requestLocation()
                    } label: {
                        Label("Add Folder…", systemImage: "folder.badge.plus")
                    }
                    Button {
                        editingServer = nil
                        connectingServer = true
                    } label: {
                        Label("Connect to Server…", systemImage: "network")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a folder or connect to a server")
            }
            if !isCompact {
                ToolbarItem {
                    Toggle(isOn: $showPreview) {
                        Image(systemName: "sidebar.right")
                    }
                    .help(showPreview ? "Hide Preview" : "Show Preview")
                }
            }
        }
        // iOS has no NSOpenPanel — the document picker grants the same
        // sandbox access, and DriveLocations bookmarks whatever comes back.
        .fileImporter(
            isPresented: $addingLocation,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { locations.add(url) }
        }
        .sheet(isPresented: $connectingServer) {
            ConnectServerSheet(servers: servers, editing: editingServer)
        }
    }

    private func isInside(_ root: URL) -> Bool {
        guard let folder = isCompact ? compactFolder : currentFolder else { return false }
        return folder.path == root.path || folder.path.hasPrefix(root.path + "/")
    }

    /// The folder the compact stack is currently showing (nil at the root).
    private var compactFolder: URL? {
        for route in path.reversed() {
            if case .folder(let url) = route { return url }
        }
        return nil
    }

    // MARK: Browser (regular layout)

    /// The regular layout's middle pane: a WebDAV server browser when one is
    /// selected, otherwise the local file browser.
    @ViewBuilder
    private var middlePane: some View {
        if let currentServer, let server = servers.server(currentServer.serverID) {
            WebDAVBrowser(
                server: server,
                location: currentServer,
                servers: servers,
                onOpenFolder: { self.currentServer = $0 },
                onOpenFile: { selection = $0 }
            )
            .id(server.id)
        } else {
            browser
        }
    }

    @ViewBuilder
    private var browser: some View {
        if let currentFolder {
            VStack(spacing: 0) {
                breadcrumbs(for: currentFolder)
                Divider().overlay(Theme.Palette.separator)
                DriveFileList(
                    folder: currentFolder,
                    roots: locations.roots,
                    selection: $selection,
                    onOpen: open
                )
            }
        } else {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 42))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(locations.roots.isEmpty
                     ? "Add a folder to start browsing"
                     : "Select a location")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func breadcrumbs(for folder: URL) -> some View {
        // Crumbs from the containing root down to the current folder.
        let root = locations.roots.first { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }
        var crumbs: [URL] = []
        if let root {
            var cursor = folder
            while cursor.path.count >= root.path.count {
                crumbs.insert(cursor, at: 0)
                if cursor.path == root.path { break }
                cursor.deleteLastPathComponent()
            }
        } else {
            crumbs = [folder]
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Button(crumb.lastPathComponent) {
                        navigate(to: crumb)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Font.cardBody.weight(index == crumbs.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == crumbs.count - 1 ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }

    // MARK: Actions

    private func requestLocation() {
        #if os(macOS)
        locations.addLocation()
        #else
        addingLocation = true
        #endif
    }

    private func removeLocation(_ root: URL) {
        if isInside(root) {
            currentFolder = nil
            path = []
            selection = nil
        }
        locations.remove(root)
    }

    private func openLocation(_ root: URL) {
        selection = nil
        if isCompact {
            path = [.folder(root)]
        } else {
            navigate(to: root)
        }
    }

    private func navigate(to folder: URL) {
        currentServer = nil
        currentFolder = folder
        selection = nil
    }

    private func openServer(_ server: DriveServer) {
        selection = nil
        let location = WebDAVLocation(serverID: server.id, url: nil)
        if isCompact {
            path = [.server(location)]
        } else {
            currentFolder = nil
            currentServer = location
        }
    }

    private func removeServer(_ server: DriveServer) {
        if currentServer?.serverID == server.id { currentServer = nil }
        if isServerActive(server) { path = []; selection = nil }
        servers.remove(server)
    }

    /// Whether the given server is the one currently being browsed (either pane).
    private func isServerActive(_ server: DriveServer) -> Bool {
        if currentServer?.serverID == server.id { return true }
        return path.contains { route in
            if case .server(let location) = route { return location.serverID == server.id }
            return false
        }
    }

    /// Row activation. On the phone every open PUSHES a screen (folders drill
    /// in, files show their preview); elsewhere folders navigate the middle
    /// pane in place and files hand off to the system.
    private func open(_ item: DriveItem) {
        if isCompact {
            path.append(item.isDirectory ? .folder(item.url) : .file(item.url))
        } else if item.isDirectory {
            navigate(to: item.url)
        } else {
            PlatformKit.open(item.url)
        }
    }

    /// Drive uses REAL Finder tags (owner decision, reaffirmed 2026-07-11
    /// after trying universal tags here): they live as file metadata, show in
    /// Finder/Apple apps, and iCloud Drive syncs them with the file itself.
    /// This one-time cleanup removes the experimental universal file links.
    private func removeUniversalFileLinksIfNeeded() {
        let flag = "tags.fileLinksRemoved"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let links = (try? modelContext.fetch(FetchDescriptor<HVTagLink>())) ?? []
        var changed = false
        for link in links where link.itemKind == "file" {
            modelContext.delete(link)
            changed = true
        }
        if changed {
            try? modelContext.save()
            NotificationCenter.default.post(name: .unifyrTagsChanged, object: nil)
        }
        UserDefaults.standard.set(true, forKey: flag)
    }
}

// MARK: - File list

/// One folder's contents plus everything you can do to them. Self-contained on
/// purpose: the regular layout hosts one of these in the middle pane, and the
/// compact layout pushes a fresh one per folder, each owning its own listing.
private struct DriveFileList: View {
    let folder: URL
    /// The Drive roots — the Finder-tag vocabulary is scanned from them.
    let roots: [URL]
    @Binding var selection: URL?
    let onOpen: (DriveItem) -> Void

    @Environment(\.isCompactLayout) private var isCompact
    @State private var items: [DriveItem] = []
    @State private var errorText: String?
    @State private var renamingItem: DriveItem?
    @State private var renameText = ""
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @AppStorage("drive.sortField") private var sortField: DriveSortField = .name
    @AppStorage("drive.sortAscending") private var sortAscending = true
    #if os(macOS)
    @State private var tagStore = FinderTagStore()
    @State private var newTagTarget: DriveItem?
    @State private var newTagName = ""
    #endif

    /// The sort is a VIEW of the listing — changing it never re-reads the disk.
    private var sortedItems: [DriveItem] {
        DriveSort.apply(items, field: sortField, ascending: sortAscending)
    }

    /// The "New Tag…" alert only exists on macOS (Finder tags do), so the body
    /// wraps the shared `core` rather than threading a `#if` through it.
    @ViewBuilder
    var body: some View {
        #if os(macOS)
        core
            .alert("New Tag", isPresented: .init(
                get: { newTagTarget != nil },
                set: { if !$0 { newTagTarget = nil } }
            )) {
                TextField("Tag name", text: $newTagName)
                Button("Create & Apply") {
                    let name = newTagName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let target = newTagTarget {
                        tagStore.addCustom(name)
                        toggleFinderTag(target, name)
                    }
                    newTagTarget = nil
                }
                Button("Cancel", role: .cancel) { newTagTarget = nil }
            } message: {
                Text("Creates a Finder tag and applies it to “\(newTagTarget?.name ?? "")”. It becomes available everywhere Finder tags are used.")
            }
        #else
        core
        #endif
    }

    private var core: some View {
        VStack(spacing: 0) {
            if let errorText {
                Text(errorText)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.danger)
                    .padding(Theme.Spacing.sm)
            }
            if items.isEmpty {
                EmptyStateLine(text: "Empty folder.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .task(id: folder) {
            reload()
            #if os(macOS)
            tagStore.refresh(locations: roots)
            #endif
        }
        .toolbar {
            ToolbarItem { sortMenu }
            ToolbarItem {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            ToolbarItem {
                Button {
                    newFolderName = ""
                    creatingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus.fill")
                }
                .help("New Folder here")
            }
        }
        .alert("Rename", isPresented: .init(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renamingItem { rename(renamingItem, to: renameText) }
                renamingItem = nil
            }
            Button("Cancel", role: .cancel) { renamingItem = nil }
        }
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder(named: newFolderName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if isCompact {
            // The phone has no hover/right-click and no preview pane: a single
            // tap opens (pushes), and destructive actions come from swipes.
            List {
                ForEach(sortedItems) { item in
                    DriveRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(item) }
                        .contextMenu { rowMenu(item) }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                trash(item)
                            }
                        }
                }
            }
        } else {
            selectableList
        }
    }

    /// Mac / iPad: click selects (driving the preview pane), double-click opens.
    @ViewBuilder
    private var selectableList: some View {
        let list = List(selection: $selection) {
            ForEach(sortedItems) { item in
                row(item)
                    .tag(item.url)
                    .contentShape(Rectangle())
                    // Simultaneous so single-click still selects the row (a
                    // plain double-click gesture swallowed selection clicks).
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(item) })
                    .simultaneousGesture(TapGesture().onEnded { selection = item.url })
                    .contextMenu { rowMenu(item) }
            }
        }
        .listStyle(.inset)
        #if os(macOS)
        list.onDeleteCommand {
            if let selection, let item = items.first(where: { $0.url == selection }) {
                trash(item)
            }
        }
        #else
        list
        #endif
    }

    @ViewBuilder
    private func row(_ item: DriveItem) -> some View {
        #if os(macOS)
        // The List draws its own selection highlight.
        DriveRow(item: item)
        #else
        // iPadOS only highlights List selection in edit mode, so paint it.
        DriveRow(item: item)
            .listRowBackground(
                selection == item.url ? Theme.Palette.primary.softFill(0.12) : Color.clear
            )
        #endif
    }

    /// Finder-style sort control: the field, then the direction.
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

    @ViewBuilder
    private func rowMenu(_ item: DriveItem) -> some View {
        Button(item.isDirectory ? "Open" : "Open with Default App") { onOpen(item) }
        #if os(macOS)
        Button("Reveal in Finder") {
            PlatformKit.reveal(item.url)
        }
        #endif
        Divider()
        Button("Rename…") {
            renameText = item.name
            renamingItem = item
        }
        Button("Duplicate") { duplicate(item) }
        #if os(macOS)
        // Real Finder tags — file metadata, visible in Finder/Apple apps,
        // synced with the file by iCloud Drive. The full vocabulary comes
        // from FinderTagStore (favorites + in-use + standard + user-created).
        // iOS has no `.tagNamesKey`, so this whole menu is Mac-only.
        Menu("Finder Tags") {
            ForEach(tagStore.allTags, id: \.self) { name in
                Button {
                    toggleFinderTag(item, name)
                } label: {
                    if item.finderTags.contains(name) {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            Divider()
            Button("New Tag…") {
                newTagName = ""
                newTagTarget = item
            }
        }
        #endif
        Button("Copy Path") {
            PlatformKit.copyToClipboard(item.url.path)
        }
        Divider()
        Button("Move to Trash", role: .destructive) { trash(item) }
    }

    // MARK: Actions

    private func reload() {
        errorText = nil

        // Hold the security scope on the OWNING ROOT for the duration of the
        // read. DriveLocations starts the scope when the location is added, but
        // that ambient grant is easy to lose — and for a network share, if it
        // never took, the read just returns an empty array with no error, which
        // is exactly the "folder looks empty" symptom. Re-establishing it here,
        // scoped to the read, is belt-and-suspenders and cheap.
        let owningRoot = roots.first { root in
            folder == root || folder.path.hasPrefix(root.path + "/")
        }
        let scoped = owningRoot?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { owningRoot?.stopAccessingSecurityScopedResource() } }

        do {
            let urls = try Self.directoryContents(of: folder)
            items = urls.map(DriveItem.init(url:))
            // An empty read from a real location is suspicious — distinguish the
            // two ways a network share fails, so a screenshot tells us which:
            //  · no grant  → security scope never took (permission).
            //  · grant, still nothing → the File Provider didn't materialize the
            //    listing even under coordination (the share is asleep/offline).
            if urls.isEmpty, owningRoot != nil {
                errorText = scoped
                    ? "This location returned no files. If it's a network server, it may be offline or asleep — open it once in the Files app to wake it, then pull to refresh."
                    : "Couldn't get access to this location. If it's a network server, open it once in the Files app (⋯ → Connect to Server), then remove and re-add it here."
            }
        } catch {
            items = []
            errorText = "Couldn't read this folder: \(error.localizedDescription)"
        }
    }

    /// List a folder's contents.
    ///
    /// On iOS a network share (an SMB volume connected in the Files app) or any
    /// third-party cloud provider is vended by a File Provider extension, and its
    /// contents are enumerated LAZILY: a plain `contentsOfDirectory` returns an
    /// empty array because the provider hasn't materialized the listing yet.
    /// (iCloud "works" only because its placeholders are already present.) A
    /// COORDINATED read asks the provider to populate the directory first, then
    /// reads it — the standard fix for "picked folder shows empty".
    private static func directoryContents(of folder: URL) throws -> [URL] {
        #if os(iOS)
        var coordinatorError: NSError?
        var readResult: Result<[URL], Error>?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordinatorError) { url in
            readResult = Result {
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: DriveItem.resourceKeys,
                    options: [.skipsHiddenFiles]
                )
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try readResult?.get() ?? []
        #else
        return try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: DriveItem.resourceKeys,
            options: [.skipsHiddenFiles]
        )
        #endif
    }

    private func rename(_ item: DriveItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            reload()
        } catch {
            errorText = "Couldn't rename “\(item.name)”."
        }
    }

    private func duplicate(_ item: DriveItem) {
        let base = item.url.deletingPathExtension().lastPathComponent
        let ext = item.url.pathExtension
        var candidate = item.url.deletingLastPathComponent()
            .appendingPathComponent("\(base) copy")
        if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = item.url.deletingLastPathComponent()
                .appendingPathComponent("\(base) copy \(counter)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: item.url, to: candidate)
            reload()
        } catch {
            errorText = "Couldn't duplicate “\(item.name)”."
        }
    }

    private func trash(_ item: DriveItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            if selection == item.url { selection = nil }
            reload()
        } catch {
            errorText = "Couldn't move “\(item.name)” to the Trash."
        }
    }

    private func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let newFolder = folder.appendingPathComponent(trimmed)
        do {
            try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: false)
            reload()
        } catch {
            errorText = "Couldn't create the folder."
        }
    }

    #if os(macOS)
    private func toggleFinderTag(_ item: DriveItem, _ name: String) {
        var tags = item.finderTags
        if let index = tags.firstIndex(of: name) {
            tags.remove(at: index)
        } else {
            tags.append(name)
        }
        do {
            try (item.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            reload()
        } catch {
            errorText = "Couldn't change the Finder tags for “\(item.name)”."
        }
    }
    #endif
}

// MARK: - Items & rows

/// One directory entry with the metadata the list shows and sorts on.
nonisolated struct DriveItem: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int?
    let modified: Date?
    /// The file's UTI — what the "Kind" sort and the preview pane read.
    let contentType: UTType?
    /// Finder tags (real ones — visible in Finder and Apple apps). Always empty
    /// on iOS: `URLResourceKey.tagNames` is macOS-only.
    let finderTags: [String]

    var id: URL { url }

    /// The keys a listing must prefetch so building items doesn't re-stat.
    static var resourceKeys: [URLResourceKey] {
        #if os(macOS)
        [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey, .tagNamesKey]
        #else
        [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey]
        #endif
    }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.isDirectory = values?.isDirectory ?? false
        self.size = values?.fileSize
        self.modified = values?.contentModificationDate
        self.contentType = values?.contentType
        #if os(macOS)
        self.finderTags = values?.tagNames ?? []
        #else
        self.finderTags = []
        #endif
    }

    /// Human-readable type — the "Kind" column's sort key and the preview's
    /// subtitle ("PNG image", "Folder"…).
    var kind: String {
        if isDirectory { return "Folder" }
        if let description = contentType?.localizedDescription { return description }
        return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
    }

    /// SF Symbol for the type. macOS shows the real NSWorkspace icon; iOS has
    /// no such API, so this is what a row draws until (or unless) Quick Look
    /// returns a thumbnail.
    var symbolName: String {
        if isDirectory { return "folder.fill" }
        guard let contentType else { return "doc" }
        if contentType.conforms(to: .image) { return "photo" }
        if contentType.conforms(to: .movie) { return "film" }
        if contentType.conforms(to: .audio) { return "music.note" }
        if contentType.conforms(to: .pdf) { return "doc.richtext" }
        if contentType.conforms(to: .archive) { return "doc.zipper" }
        if contentType.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if contentType.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// Quick Look renderings, bridged to the platform image type (QL returns a
/// CGImage on both platforms, so one path serves Mac and iOS).
enum DriveThumbnail {
    static func generate(
        for url: URL,
        size: CGSize,
        representations: QLThumbnailGenerator.Request.RepresentationTypes
    ) async -> PlatformImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2,
            representationTypes: representations
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        return PlatformImage.fromCGImage(representation.cgImage)
    }
}

/// A file's icon. macOS asks NSWorkspace (instant, always right); iOS has no
/// equivalent, so it asks Quick Look for an icon representation and shows the
/// UTType's SF Symbol until one arrives — or forever, if none does.
private struct DriveIcon: View {
    let item: DriveItem
    let size: CGFloat

    @State private var icon: PlatformImage?

    var body: some View {
        Group {
            if let icon {
                Image(platformImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: item.symbolName)
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(Theme.Palette.primary)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.url) {
            if let systemIcon = PlatformKit.fileIcon(for: item.url) {
                icon = systemIcon
                return
            }
            guard !item.isDirectory else { return }
            icon = await DriveThumbnail.generate(
                for: item.url,
                size: CGSize(width: size, height: size),
                representations: .icon
            )
        }
    }
}

/// Right-side (or, on the phone, pushed) preview: Quick Look rendering — works
/// for images, PDFs, video frames, documents — inline text for plain-text
/// files, plus the metadata.
private struct DrivePreviewPane: View {
    let item: DriveItem
    let onOpen: () -> Void

    @State private var thumbnail: PlatformImage?
    @State private var textPreview: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    previewContent
                    VStack(spacing: 3) {
                        Text(item.name)
                            .font(Theme.Font.cardBody.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Text(item.kind)
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        if !item.isDirectory, let size = item.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        if let modified = item.modified {
                            Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        if !item.finderTags.isEmpty {
                            Text(item.finderTags.joined(separator: " · "))
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity)
            }
            actions
                .padding(.bottom, Theme.Spacing.md)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.Palette.surface)
        .task { await loadPreview() }
    }

    /// The Mac opens files in their default app and reveals them in Finder;
    /// iOS has neither verb — the share sheet is how a file leaves the app.
    @ViewBuilder
    private var actions: some View {
        #if os(macOS)
        HStack {
            Button("Open", action: onOpen)
            Button("Reveal in Finder") {
                PlatformKit.reveal(item.url)
            }
        }
        #else
        if !item.isDirectory {
            ShareLink(item: item.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        #endif
    }

    @ViewBuilder
    private var previewContent: some View {
        if let textPreview {
            Text(textPreview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.sm)
                .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        } else if let thumbnail {
            Image(platformImage: thumbnail)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        } else {
            DriveIcon(item: item, size: 96)
        }
    }

    private func loadPreview() async {
        guard !item.isDirectory else { return }
        // Small plain-text files render as text; everything else via Quick Look.
        if let type = item.contentType,
           type.conforms(to: .text) || type.conforms(to: .sourceCode),
           let size = item.size, size < 200_000,
           let data = try? Data(contentsOf: item.url),
           let string = String(data: data, encoding: .utf8) {
            textPreview = String(string.prefix(4000))
            return
        }
        thumbnail = await DriveThumbnail.generate(
            for: item.url,
            size: CGSize(width: 512, height: 512),
            representations: .thumbnail
        )
    }
}

private struct DriveRow: View {
    let item: DriveItem

    /// Finder's standard tag-name → color mapping (macOS only; `finderTags` is
    /// always empty on iOS, so the dots simply never render there).
    private static let tagColors: [String: Color] = [
        "Red": .red, "Orange": .orange, "Yellow": .yellow,
        "Green": .green, "Blue": .blue, "Purple": .purple, "Gray": .gray,
    ]

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            DriveIcon(item: item, size: 18)
            Text(item.name)
                .font(Theme.Font.cardBody)
                .lineLimit(1)
            HStack(spacing: 2) {
                ForEach(item.finderTags.prefix(4), id: \.self) { tag in
                    Circle()
                        .fill(Self.tagColors[tag] ?? Theme.Palette.primary)
                        .frame(width: 7, height: 7)
                        .help(tag)
                }
            }
            Spacer()
            if !item.isDirectory, let size = item.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 74, alignment: .trailing)
            }
            if let modified = item.modified {
                Text(modified.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 140, alignment: .trailing)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}
