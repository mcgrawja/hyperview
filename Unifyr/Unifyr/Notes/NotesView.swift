//
//  NotesView.swift
//  Unifyr
//
//  The Notes module, Notion-style (2026-07-22 refocus): ONE page tree — pages
//  nest inside pages (`Note.parentNoteID`), databases are pages, folders are
//  gone from the UI. Left: favorites + tree + tags + trash. Right: the
//  selected page (breadcrumbs, icon, title, sub-pages, block editor or
//  database). Ordering uses String sort keys (§4.1); mutations go through
//  NotesStore; lists are @Query-driven.
//

import SwiftUI
import SwiftData
import QuickLook
import UniformTypeIdentifiers

struct NotesView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Note.sortKey) private var notes: [Note]
    @Query(sort: \HVTag.name) private var allTags: [HVTag]
    @Query private var tagLinks: [HVTagLink]

    @State private var selectedNote: Note?
    @State private var selectedTagID: UUID?
    /// Recently Deleted is a mode, not a page — a trashed page shows nowhere else.
    @State private var showingTrash = false
    /// Collapsed page ids, comma-separated — a per-device view preference.
    @AppStorage("notes.collapsedPages") private var collapsedPagesRaw = ""
    /// Tags section fold (Jason, 2026-07-22) — per-device.
    @AppStorage("notes.tagsCollapsed") private var tagsCollapsed = false
    @State private var showingNoteLinkPicker = false
    @Environment(\.isCompactLayout) private var isCompact
    // iOS file links: the editor can't open a modal panel, so this view owns
    // the document picker and the Quick Look preview.
    @State private var showingFileImporter = false
    @State private var showingImageImporter = false
    @State private var showingDBEmbedPicker = false
    @State private var previewURL: URL?

    private var store: NotesStore { NotesStore(context: context) }

    private var noteByID: [UUID: Note] {
        Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
    }

    /// Trashed pages, newest first — shown only in Recently Deleted.
    private var trashedNotes: [Note] {
        notes.filter(\.isTrashed).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Deleting takes the subtree, so the trash shows only subtree ROOTS —
    /// restoring one brings its children back with it.
    private var trashRoots: [Note] {
        let byID = noteByID
        return trashedNotes.filter { note in
            guard let parentID = note.parentNoteID, let parent = byID[parentID] else { return true }
            return !parent.isTrashed
        }
    }

    private var favorites: [Note] {
        notes.filter { $0.isFavorite && !$0.isTrashed && !$0.isArchived }
    }

    var body: some View {
        Group {
            if isCompact {
                // iPhone: page tree, drill into the page.
                NavigationStack {
                    listPane
                        .navigationTitle("Notes")
                        .navigationDestination(item: $selectedNote) { note in
                            pageHost(note)
                                .id(note.id)
                                .inlineNavigationTitle()
                        }
                }
            } else {
                PlatformHSplit {
                    listPane
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    detailPane
                        .frame(minWidth: 380)
                }
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Notes")
        // Editor slash command "Link to note" → show the picker; the choice
        // goes back to the editor bridge as an insertNoteLink notification.
        .onReceive(NotificationCenter.default.publisher(for: .unifyrRequestNoteLink)) { _ in
            showingNoteLinkPicker = true
        }
        // A hyperview://note/<uuid> link was clicked in the editor, or a
        // deep link arrived (dashboard pin / search) — the .task consumes a
        // latch that landed while this module was still mounting.
        .onReceive(NotificationCenter.default.publisher(for: .unifyrOpenNote)) { notification in
            DeepLink.take(.unifyrOpenNote)
            guard let id = notification.userInfo?["id"] as? UUID else { return }
            openNoteByID(id)
        }
        .task {
            if let info = DeepLink.take(.unifyrOpenNote), let id = info["id"] as? UUID {
                openNoteByID(id)
            }
        }
        .sheet(isPresented: $showingNoteLinkPicker) {
            NoteLinkPicker(notes: notes.filter { !$0.isArchived && !$0.isTrashed && $0.id != selectedNote?.id }) { note in
                NotificationCenter.default.post(
                    name: .unifyrInsertNoteLink,
                    object: nil,
                    userInfo: [
                        "href": "hyperview://note/\(note.id.uuidString)",
                        "text": note.title.isEmpty ? "Untitled" : note.title,
                    ]
                )
            }
        }
        // iOS "Link to file": the editor asks, we present the document picker.
        .onReceive(NotificationCenter.default.publisher(for: .unifyrRequestFileLink)) { _ in
            showingFileImporter = true
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            FileLinkBookmarks.save(url)
            NotificationCenter.default.post(
                name: .unifyrInsertNoteLink,
                object: nil,
                userInfo: ["href": url.absoluteString, "text": url.lastPathComponent]
            )
        }
        // "/Linked database": pick a database (and optionally a saved view)
        // to embed; the bridge inserts the dbembed block.
        .onReceive(NotificationCenter.default.publisher(for: .unifyrRequestDBEmbedPicker)) { _ in
            showingDBEmbedPicker = true
        }
        .sheet(isPresented: $showingDBEmbedPicker) {
            DatabaseEmbedPicker { databaseID, viewID, title, emoji in
                var userInfo: [String: Any] = ["id": databaseID, "title": title]
                if let viewID { userInfo["viewID"] = viewID }
                if let emoji { userInfo["emoji"] = emoji }
                NotificationCenter.default.post(name: .unifyrInsertDBEmbed, object: nil, userInfo: userInfo)
            }
        }
        // iOS "Image" slash command: the editor asks, we present the picker;
        // the bridge stores the Asset and inserts the block.
        .onReceive(NotificationCenter.default.publisher(for: .unifyrRequestImageFile)) { _ in
            showingImageImporter = true
        }
        .fileImporter(isPresented: $showingImageImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            NotificationCenter.default.post(
                name: .unifyrInsertImageFile,
                object: nil,
                userInfo: ["url": url]
            )
        }
        // iOS: a clicked file link previews with Quick Look.
        .onReceive(NotificationCenter.default.publisher(for: .unifyrOpenFileLink)) { notification in
            guard let href = notification.userInfo?["href"] as? String else { return }
            previewURL = FileLinkBookmarks.resolve(href)
        }
        .quickLookPreview($previewURL)
    }

    // MARK: List pane (the page tree)

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Notes").font(Theme.Font.cardTitle)
                Spacer()
                Button(action: { addDatabase(parent: nil) }) { Image(systemName: "tablecells") }
                    .buttonStyle(.plain).help("New Database")
                Button(action: { addPage(parent: nil) }) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("New Page")
            }
            .padding(Theme.Spacing.md)

            List(selection: $selectedNote) {
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { note in
                            pageRow(note, depth: 0, showsChevron: false).tag(note)
                        }
                    }
                }

                Section("Pages") {
                    if let selectedTagID {
                        // A tag filters the tree down to a flat matching list.
                        ForEach(taggedNotes(selectedTagID)) { note in
                            pageRow(note, depth: 0, showsChevron: false).tag(note)
                        }
                    } else {
                        ForEach(flattenedPages, id: \.note.id) { entry in
                            pageRow(entry.note, depth: entry.depth, showsChevron: true).tag(entry.note)
                        }
                        Button {
                            addPage(parent: nil)
                        } label: {
                            Label("New Page", systemImage: "plus")
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !allTags.isEmpty {
                    Section {
                        if !tagsCollapsed {
                            ForEach(allTags) { tag in
                                Button {
                                    selectedTagID = selectedTagID == tag.id ? nil : tag.id
                                } label: {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        Circle()
                                            .fill(Color(hexString: tag.colorHex) ?? Theme.Palette.primary)
                                            .frame(width: 9, height: 9)
                                        Text(tag.name).lineLimit(1)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(
                                    selectedTagID == tag.id ? Theme.Palette.primary.softFill(0.12) : Color.clear
                                )
                            }
                        }
                    } header: {
                        // Collapsible (Jason): the twist folds the whole tag
                        // list; collapsing also clears an active tag filter so
                        // the tree doesn't stay silently filtered.
                        Button {
                            tagsCollapsed.toggle()
                            if tagsCollapsed { selectedTagID = nil }
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Text("Tags")
                                Image(systemName: tagsCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                Spacer()
                                if tagsCollapsed {
                                    Text("\(allTags.count)")
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !trashRoots.isEmpty {
                    Section {
                        Button {
                            showingTrash.toggle()
                            if showingTrash { selectedTagID = nil }
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "trash")
                                Text("Recently Deleted")
                                Spacer()
                                Text("\(trashRoots.count)")
                                    .font(Theme.Font.cardCaption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(showingTrash ? Theme.Palette.primary.softFill(0.12) : Color.clear)

                        if showingTrash {
                            ForEach(trashRoots) { note in
                                trashRow(note)
                            }
                            Button("Empty Trash") {
                                if selectedNote?.isTrashed == true { selectedNote = nil }
                                store.emptyTrash(trashedNotes)
                                try? context.save()
                                showingTrash = false
                            }
                            .buttonStyle(.plain)
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.danger)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Theme.Palette.surface)
    }

    // MARK: Tree flattening

    private var collapsedPages: Set<UUID> {
        Set(collapsedPagesRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func isCollapsed(_ note: Note) -> Bool {
        collapsedPages.contains(note.id)
    }

    private func toggleCollapsed(_ note: Note) {
        var collapsed = collapsedPages
        if collapsed.contains(note.id) {
            collapsed.remove(note.id)
        } else {
            collapsed.insert(note.id)
        }
        collapsedPagesRaw = collapsed.map(\.uuidString).joined(separator: ",")
    }

    /// Live children of a page (or the top level, for nil).
    private func children(of parentID: UUID?) -> [Note] {
        notes.filter { $0.parentNoteID == parentID && !$0.isTrashed && !$0.isArchived }
    }

    private func hasChildren(_ note: Note) -> Bool {
        notes.contains { $0.parentNoteID == note.id && !$0.isTrashed && !$0.isArchived }
    }

    /// The page tree flattened depth-first (indentation = depth). A collapsed
    /// page still shows — its descendants don't. Pages whose parent vanished
    /// in a partial sync surface at the top level rather than disappearing.
    private var flattenedPages: [(note: Note, depth: Int)] {
        let collapsed = collapsedPages
        var result: [(Note, Int)] = []
        func walk(_ parentID: UUID?, depth: Int) {
            guard depth < 16 else { return } // cycle guard
            for note in children(of: parentID) {
                result.append((note, depth))
                guard !collapsed.contains(note.id) else { continue }
                walk(note.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        // Orphan rescue — but a page merely HIDDEN under a collapsed ancestor
        // is not an orphan, so re-walk ignoring collapse to tell them apart.
        var reachable = Set<UUID>()
        func markReachable(_ parentID: UUID?, depth: Int) {
            guard depth < 16 else { return }
            for note in children(of: parentID) {
                reachable.insert(note.id)
                markReachable(note.id, depth: depth + 1)
            }
        }
        markReachable(nil, depth: 0)
        for note in notes
        where !note.isTrashed && !note.isArchived && !reachable.contains(note.id) {
            result.append((note, 0))
        }
        return result.map { (note: $0.0, depth: $0.1) }
    }

    private func taggedNotes(_ tagID: UUID) -> [Note] {
        let keys = Set(
            tagLinks
                .filter { $0.tagID == tagID && $0.itemKind == TagKind.note }
                .map(\.itemKey)
        )
        return notes.filter { !$0.isTrashed && !$0.isArchived && keys.contains($0.id.uuidString) }
    }

    /// Pages that may become `note`'s parent (not itself, not a descendant,
    /// not a database — rows are a database's children, not pages).
    private func validParents(for note: Note) -> [Note] {
        var excluded = Set(store.descendants(of: note, in: notes).map(\.id))
        excluded.insert(note.id)
        return notes.filter {
            !excluded.contains($0.id) && !$0.isTrashed && !$0.isArchived && $0.kind == .page
        }
    }

    /// Open a specific page (deep link / in-editor note link), expanding its
    /// ancestors so the selection is actually visible in the tree.
    private func openNoteByID(_ id: UUID) {
        guard let target = notes.first(where: { $0.id == id }) else { return }
        var collapsed = collapsedPages
        var cursor = target.parentNoteID
        var hops = 0
        while let parentID = cursor, hops < 16 {
            collapsed.remove(parentID)
            cursor = noteByID[parentID]?.parentNoteID
            hops += 1
        }
        collapsedPagesRaw = collapsed.map(\.uuidString).joined(separator: ",")
        selectedTagID = nil
        selectedNote = target
    }

    // MARK: Rows

    private func pageRow(_ note: Note, depth: Int, showsChevron: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            if showsChevron, hasChildren(note) {
                Button {
                    toggleCollapsed(note)
                } label: {
                    Image(systemName: isCollapsed(note) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if showsChevron {
                // Keeps childless pages' titles aligned with their siblings'.
                Color.clear.frame(width: 12, height: 12)
            }

            Text(note.emoji ?? (note.kind == .database ? "📊" : "📄"))
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(Theme.Font.cardBody)
                .lineLimit(1)
            TagDots(kind: TagKind.note, key: note.id.uuidString)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contextMenu {
            if note.kind == .page {
                Button("New Sub-page") { addPage(parent: note) }
                Button("New Sub-database") { addDatabase(parent: note) }
            }
            Button(note.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                store.toggleFavorite(note)
                try? context.save()
            }
            Menu("Move To") {
                if note.parentNoteID != nil {
                    Button("Top Level") { move(note, to: nil) }
                }
                ForEach(validParents(for: note)) { parent in
                    Button(pageLabel(parent)) { move(note, to: parent) }
                }
            }
            moveUpDownButtons(note)
            Button("Duplicate") {
                let copy = store.duplicate(note, in: notes)
                try? context.save()
                selectedNote = copy
            }
            Divider()
            TagMenu(kind: TagKind.note, key: note.id.uuidString)
            Button(PinStore.isPinned(note: note.id) ? "Unpin from Dashboard" : "Pin to Dashboard") {
                PinStore.toggle(note: note.id)
            }
            Divider()
            Button("Delete", role: .destructive) { delete(note) }
        }
        // Swipe is the phone idiom; a context menu is a long-press away.
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { delete(note) }
        }
    }

    @ViewBuilder
    private func moveUpDownButtons(_ note: Note) -> some View {
        let siblings = children(of: note.parentNoteID)
        Button("Move Up") {
            store.movePage(note, offset: -1, within: siblings)
            try? context.save()
        }
        .disabled(siblings.first?.id == note.id)
        Button("Move Down") {
            store.movePage(note, offset: 1, within: siblings)
            try? context.save()
        }
        .disabled(siblings.last?.id == note.id)
    }

    private func trashRow(_ note: Note) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(note.emoji ?? (note.kind == .database ? "📊" : "📄"))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(Theme.Font.cardBody)
                    .lineLimit(1)
                if let deletedAt = note.deletedAt {
                    Text("Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Put Back") { restore(note) }
            Divider()
            Button("Delete Permanently", role: .destructive) { deleteForever(note) }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { deleteForever(note) }
            Button("Put Back") { restore(note) }
                .tint(Theme.Palette.primary)
        }
    }

    private func pageLabel(_ note: Note) -> String {
        "\(note.emoji ?? (note.kind == .database ? "📊" : "📄")) \(note.title.isEmpty ? "Untitled" : note.title)"
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let selectedNote {
            pageHost(selectedNote)
        } else {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "doc.text")
                    .font(.system(size: 42))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Select or create a page")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Button("New Page") { addPage(parent: nil) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pageHost(_ note: Note) -> some View {
        PageHost(
            note: note,
            allNotes: notes,
            open: { openNoteByID($0.id) },
            addSubPage: { parent, database in
                database ? addDatabase(parent: parent) : addPage(parent: parent)
            }
        )
    }

    // MARK: Actions

    private func addPage(parent: Note?) {
        let note = store.createPage(parent: parent)
        try? context.save()
        if let parent, isCollapsed(parent) { toggleCollapsed(parent) }
        selectedTagID = nil
        selectedNote = note
    }

    /// A database IS a page (kind == .database), just seeded with a schema.
    private func addDatabase(parent: Note?) {
        let note = store.createPage(parent: parent)
        DatabaseStore(context: context).seedNewDatabase(note)
        try? context.save()
        if let parent, isCollapsed(parent) { toggleCollapsed(parent) }
        selectedTagID = nil
        selectedNote = note
    }

    private func move(_ note: Note, to parent: Note?) {
        store.move(note, toParent: parent, in: notes)
        try? context.save()
        if let parent, isCollapsed(parent) { toggleCollapsed(parent) }
    }

    /// Move the page AND its subtree to Recently Deleted (reversible).
    private func delete(_ note: Note) {
        if let selectedNote,
           selectedNote.id == note.id
            || store.descendants(of: note, in: notes).contains(where: { $0.id == selectedNote.id }) {
            self.selectedNote = nil
        }
        store.delete(note, in: notes)
        try? context.save()
    }

    private func restore(_ note: Note) {
        store.restore(note, in: notes)
        try? context.save()
        if trashRoots.isEmpty { showingTrash = false }
    }

    private func deleteForever(_ note: Note) {
        if selectedNote?.id == note.id { selectedNote = nil }
        store.deletePermanently(note, in: notes)
        try? context.save()
        if trashRoots.isEmpty { showingTrash = false }
    }
}

// MARK: - Page host (breadcrumbs · icon · title · sub-pages · content)

private struct PageHost: View {
    @Environment(\.modelContext) private var context
    @Bindable var note: Note
    let allNotes: [Note]
    let open: (Note) -> Void
    /// (parent, isDatabase)
    let addSubPage: (Note, Bool) -> Void

    @State private var showingCheatsheet = false
    @State private var showingIconPicker = false
    @State private var showingCoverPicker = false
    @State private var showingCoverImporter = false
    /// Drag-to-reposition mode for image covers.
    @State private var repositioningCover = false
    /// Pages whose content links here (link hrefs, @-mentions, subpage
    /// embeds). Computed on page open, not live — cheap and good enough.
    @State private var backlinks: [Note] = []

    private var byID: [UUID: Note] {
        Dictionary(uniqueKeysWithValues: allNotes.map { ($0.id, $0) })
    }

    /// Ancestors, outermost first (cycle-guarded).
    private var breadcrumbs: [Note] {
        var chain: [Note] = []
        var cursor = note.parentNoteID
        var hops = 0
        while let parentID = cursor, hops < 16, let parent = byID[parentID] {
            chain.append(parent)
            cursor = parent.parentNoteID
            hops += 1
        }
        return chain.reversed()
    }

    private var subPages: [Note] {
        allNotes.filter { $0.parentNoteID == note.id && !$0.isTrashed && !$0.isArchived }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if note.pageProps.hasCover {
                PageCoverView(
                    note: note,
                    repositioning: repositioningCover,
                    onCommitOffset: { fraction in
                        var props = note.pageProps
                        props.coverOffsetY = abs(fraction - 0.5) < 0.01 ? nil : fraction
                        note.pageProps = props
                        try? context.save()
                    }
                )
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if repositioningCover {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text("Drag the photo to position it")
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textOnAccent)
                            Button("Done") { repositioningCover = false }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.Palette.primary)
                                .controlSize(.small)
                        }
                        .padding(Theme.Spacing.sm)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(Theme.Spacing.md)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if !repositioningCover { showingCoverPicker = true }
                }
                .contextMenu {
                    Button("Change Cover…") { showingCoverPicker = true }
                    if note.pageProps.coverKind == "asset" {
                        Button("Reposition Cover") { repositioningCover = true }
                    }
                    Button("Remove Cover", role: .destructive) {
                        var props = note.pageProps
                        props.coverKind = nil
                        props.coverHex = nil
                        props.coverHex2 = nil
                        props.coverAssetID = nil
                        props.coverOffsetY = nil
                        note.pageProps = props
                        try? context.save()
                    }
                }
            }

            if !breadcrumbs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(breadcrumbs) { ancestor in
                            Button {
                                open(ancestor)
                            } label: {
                                Text("\(ancestor.emoji ?? (ancestor.kind == .database ? "📊" : "📄")) \(ancestor.title.isEmpty ? "Untitled" : ancestor.title)")
                                    .font(Theme.Font.cardCaption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Text("/")
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.md)
            }

            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Button {
                    showingIconPicker = true
                } label: {
                    Text(note.emoji ?? (note.kind == .database ? "📊" : "📄"))
                        .font(.system(size: 30))
                        .opacity(note.emoji == nil ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .help("Change icon")
                .popover(isPresented: $showingIconPicker) {
                    EmojiIconPicker(emoji: $note.emoji)
                }

                TextField("Untitled", text: $note.title)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.dashboardTitle)
                    .onChange(of: note.title) { _, _ in note.modifiedAt = Date() }

                if note.kind == .page {
                    Button {
                        showingCheatsheet.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.title3)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Markdown shortcuts")
                    .popover(isPresented: $showingCheatsheet, arrowEdge: .top) {
                        MarkdownCheatsheet()
                    }
                }

                // Page options: cover, layout, duplicate.
                Menu {
                    Button(note.pageProps.hasCover ? "Change Cover…" : "Add Cover…") {
                        showingCoverPicker = true
                    }
                    if note.pageProps.coverKind == "asset" {
                        Button("Reposition Cover") { repositioningCover = true }
                    }
                    if note.pageProps.hasCover {
                        Button("Remove Cover", role: .destructive) {
                            var props = note.pageProps
                            props.coverKind = nil
                            props.coverHex = nil
                            props.coverHex2 = nil
                            props.coverAssetID = nil
                            props.coverOffsetY = nil
                            note.pageProps = props
                            try? context.save()
                        }
                    }
                    if note.kind == .page {
                        Divider()
                        Button((note.pageProps.wideLayout ?? false) ? "Centered Layout" : "Full-Width Layout") {
                            var props = note.pageProps
                            props.wideLayout = (props.wideLayout ?? false) ? nil : true
                            note.pageProps = props
                            try? context.save()
                        }
                    }
                    Divider()
                    Button("Duplicate Page") {
                        let copy = NotesStore(context: context).duplicate(note, in: allNotes)
                        try? context.save()
                        open(copy)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .popover(isPresented: $showingCoverPicker) {
                    CoverPicker(note: note) {
                        showingCoverImporter = true
                    }
                }
                .fileImporter(isPresented: $showingCoverImporter, allowedContentTypes: [.image]) { result in
                    guard case .success(let url) = result else { return }
                    setImageCover(from: url)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, breadcrumbs.isEmpty ? Theme.Spacing.lg : Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.sm)

            // Sub-pages, Notion-style, right under the title. (Inline sub-page
            // BLOCKS are a later phase — this strip is the navigation.)
            if note.kind == .page, !subPages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(subPages) { child in
                            Button {
                                open(child)
                            } label: {
                                Text("\(child.emoji ?? (child.kind == .database ? "📊" : "📄")) \(child.title.isEmpty ? "Untitled" : child.title)")
                                    .font(Theme.Font.cardCaption)
                                    .lineLimit(1)
                                    .padding(.horizontal, Theme.Spacing.sm)
                                    .padding(.vertical, Theme.Spacing.xs)
                                    .background(Theme.Palette.surfaceRaised, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Menu {
                            Button("New Sub-page") { addSubPage(note, false) }
                            Button("New Sub-database") { addSubPage(note, true) }
                        } label: {
                            Image(systemName: "plus")
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .padding(Theme.Spacing.xs)
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.sm)
            }

            // Backlinks — every page that references this one.
            if !backlinks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Label("Linked from", systemImage: "arrow.uturn.backward")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        ForEach(backlinks) { source in
                            Button {
                                open(source)
                            } label: {
                                Text("\(source.emoji ?? (source.kind == .database ? "📊" : "📄")) \(source.title.isEmpty ? "Untitled" : source.title)")
                                    .font(Theme.Font.cardCaption)
                                    .lineLimit(1)
                                    .padding(.horizontal, Theme.Spacing.sm)
                                    .padding(.vertical, Theme.Spacing.xs)
                                    .background(Theme.Palette.primary.softFill(0.10), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.sm)
            }

            if note.kind == .database {
                // .id: DatabaseView's @Query predicates are built in its init,
                // so switching databases must re-create the view.
                DatabaseView(note: note).id(note.id)
            } else {
                // No .id(note.id): the bridge swaps documents into the EXISTING
                // web view (EditorBridge.show) — re-creating the WKWebView per
                // note would reload TipTap on every selection.
                NoteEditorWebView(note: note, store: NotesStore(context: context))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Palette.background)
        .task(id: note.id) {
            backlinks = NotesStore(context: context).backlinkSources(to: note.id)
        }
    }

    /// Picked cover image → Asset → asset cover.
    private func setImageCover(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        let asset = Asset(noteID: note.id, filename: url.lastPathComponent, mimeType: mimeType, data: data)
        context.insert(asset)
        var props = note.pageProps
        props.coverKind = "asset"
        props.coverHex = nil
        props.coverHex2 = nil
        props.coverAssetID = asset.id
        note.pageProps = props
        try? context.save()
    }
}

// MARK: - Page covers (Phase 5; repositioning added on Jason's request)

/// The cover band: preset color, gradient, or an Asset image. Image covers
/// honor `coverOffsetY` (which slice of the photo the band shows), and in
/// repositioning mode a vertical drag adjusts it live.
private struct PageCoverView: View {
    let note: Note
    var repositioning = false
    /// Called with the final offset when a reposition drag ends.
    var onCommitOffset: ((Double) -> Void)? = nil

    @Environment(\.modelContext) private var context
    /// Live value while dragging (committed on release).
    @State private var dragFraction: Double?

    var body: some View {
        let props = note.pageProps
        switch props.coverKind {
        case "color":
            (Color(hexString: props.coverHex ?? "") ?? Theme.Palette.primary).opacity(0.85)
        case "gradient":
            LinearGradient(
                colors: [
                    Color(hexString: props.coverHex ?? "") ?? Theme.Palette.primary,
                    Color(hexString: props.coverHex2 ?? "") ?? Theme.Palette.claude,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.85)
        case "asset":
            if let assetID = props.coverAssetID, let image = coverImage(assetID) {
                positionedImage(image, storedFraction: props.coverOffsetY ?? 0.5)
            } else {
                Theme.Palette.surfaceRaised
            }
        default:
            Theme.Palette.surfaceRaised
        }
    }

    /// scaledToFill by hand so the vertical crop is controllable: the image
    /// covers the band, and `fraction` picks which slice shows (0 top, 1
    /// bottom). SwiftUI's own scaledToFill always center-crops.
    private func positionedImage(_ image: PlatformImage, storedFraction: Double) -> some View {
        GeometryReader { geo in
            let bandHeight = geo.size.height
            let imageSize = image.size
            let scale = max(
                geo.size.width / max(imageSize.width, 1),
                bandHeight / max(imageSize.height, 1)
            )
            let displayedWidth = imageSize.width * scale
            let displayedHeight = imageSize.height * scale
            let range = max(0, displayedHeight - bandHeight)
            let fraction = dragFraction ?? storedFraction

            Image(platformImage: image)
                .resizable()
                .frame(width: displayedWidth, height: displayedHeight)
                .offset(
                    x: (geo.size.width - displayedWidth) / 2,
                    y: -fraction * range
                )
                .gesture(repositioning ? repositionGesture(startFraction: storedFraction, range: range) : nil)
        }
    }

    private func repositionGesture(startFraction: Double, range: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard range > 0 else { return }
                // Dragging DOWN reveals more of the top → smaller fraction.
                let delta = Double(-value.translation.height / range)
                dragFraction = min(1, max(0, startFraction + delta))
            }
            .onEnded { _ in
                if let dragFraction { onCommitOffset?(dragFraction) }
                dragFraction = nil
            }
    }

    private func coverImage(_ id: UUID) -> PlatformImage? {
        var descriptor = FetchDescriptor<Asset>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let asset = ((try? context.fetch(descriptor)) ?? []).first else { return nil }
        return PlatformImage(data: asset.data)
    }
}

/// Preset cover picker: gradients, solids, or an image from disk.
private struct CoverPicker: View {
    @Bindable var note: Note
    let chooseImage: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Gradients")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72)), count: 3), spacing: Theme.Spacing.sm) {
                ForEach(Array(CoverPresets.gradients.enumerated()), id: \.offset) { _, pair in
                    Button {
                        apply(kind: "gradient", hex: pair.0, hex2: pair.1)
                    } label: {
                        LinearGradient(
                            colors: [Color(hexString: pair.0) ?? .blue, Color(hexString: pair.1) ?? .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: 72, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Colors")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72)), count: 3), spacing: Theme.Spacing.sm) {
                ForEach(CoverPresets.colors, id: \.self) { hex in
                    Button {
                        apply(kind: "color", hex: hex, hex2: nil)
                    } label: {
                        (Color(hexString: hex) ?? .blue)
                            .frame(width: 72, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                dismiss()
                chooseImage()
            } label: {
                Label("Choose Image…", systemImage: "photo")
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: 270)
    }

    private func apply(kind: String, hex: String?, hex2: String?) {
        var props = note.pageProps
        props.coverKind = kind
        props.coverHex = hex
        props.coverHex2 = hex2
        props.coverAssetID = nil
        note.pageProps = props
        try? context.save()
        dismiss()
    }
}

// MARK: - Emoji icon picker

/// A small curated grid + free-form field. (The system emoji palette can't be
/// summoned into a popover reliably on both platforms; this covers the common
/// cases and the field takes anything.)
private struct EmojiIconPicker: View {
    @Binding var emoji: String?
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""

    private static let common: [String] = [
        "📄", "📝", "📚", "📖", "📌", "📋", "🗂️", "🗒️",
        "💡", "🎯", "🚀", "⭐️", "🔥", "✅", "🧠", "🛠️",
        "🏠", "🏢", "🛒", "💰", "📈", "📊", "🗓️", "⏰",
        "🍽️", "✈️", "🏋️", "🚗", "🖨️", "🎮", "🎵", "🎬",
        "❤️", "🌟", "🌱", "🌊", "🐾", "🎁", "🔒", "🔑",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 8), spacing: Theme.Spacing.xs) {
                ForEach(Self.common, id: \.self) { candidate in
                    Button {
                        emoji = candidate
                        dismiss()
                    } label: {
                        Text(candidate).font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                TextField("Any emoji…", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyCustom)
                Button("Set", action: applyCustom)
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                if emoji != nil {
                    Button("Remove") {
                        emoji = nil
                        dismiss()
                    }
                    .foregroundStyle(Theme.Palette.danger)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: 330)
    }

    private func applyCustom() {
        let trimmed = custom.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return }
        emoji = String(first)
        dismiss()
    }
}

// MARK: - Note link picker

/// "Link to note" picker: searchable list of pages; choosing one posts the
/// link back to the editor bridge.
private struct NoteLinkPicker: View {
    let notes: [Note]
    let onPick: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return notes }
        return notes.filter {
            ($0.title.isEmpty ? "Untitled" : $0.title).localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("Search pages…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if let first = filtered.first { pick(first) }
                    }
            }
            .padding(Theme.Spacing.md)

            Divider().overlay(Theme.Palette.separator)

            if filtered.isEmpty {
                EmptyStateLine(text: "No matching pages.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { note in
                    Button {
                        pick(note)
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(note.emoji ?? (note.kind == .database ? "📊" : "📄"))
                            Text(note.title.isEmpty ? "Untitled" : note.title)
                                .font(Theme.Font.cardBody)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            Divider().overlay(Theme.Palette.separator)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Spacing.md)
        }
        .frame(width: 380, height: 420)
        .background(Theme.Palette.background)
    }

    private func pick(_ note: Note) {
        onPick(note)
        dismiss()
    }
}
