//
//  NotesView.swift
//  Hyperview
//
//  Phase 2 Notes module: folder sidebar + note list + editor detail. The
//  Notion-lite store (D4) — no Apple Notes. Ordering uses String sort keys
//  (§4.1). Mutations go through NotesStore; lists are @Query-driven.
//

import SwiftUI
import SwiftData
import QuickLook
import UniformTypeIdentifiers

struct NotesView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Folder.sortKey) private var folders: [Folder]
    @Query(sort: \Note.sortKey) private var notes: [Note]
    @Query(sort: \HVTag.name) private var allTags: [HVTag]
    @Query private var tagLinks: [HVTagLink]
    @State private var selectedTagID: UUID?

    @State private var selectedFolder: Folder?
    @State private var selectedNote: Note?
    /// Recently Deleted is a mode, not a folder — a trashed note has no folder.
    @State private var showingTrash = false
    @State private var showingNoteLinkPicker = false
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    @Environment(\.isCompactLayout) private var isCompact
    // iOS file links: the editor can't open a modal panel, so this view owns
    // the document picker and the Quick Look preview.
    @State private var showingFileImporter = false
    @State private var previewURL: URL?

    private var store: NotesStore { NotesStore(context: context) }

    /// Notes in the trash, newest first — shown only in Recently Deleted.
    private var trashedNotes: [Note] {
        notes.filter(\.isTrashed).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    private var visibleNotes: [Note] {
        if showingTrash { return trashedNotes }

        var result = notes.filter { note in
            // A trashed note is invisible everywhere but the trash.
            !note.isTrashed
                && !note.isArchived
                && (selectedFolder == nil || note.folder?.id == selectedFolder?.id)
        }
        if let selectedTagID {
            let keys = Set(
                tagLinks
                    .filter { $0.tagID == selectedTagID && $0.itemKind == TagKind.note }
                    .map(\.itemKey)
            )
            result = result.filter { keys.contains($0.id.uuidString) }
        }
        return result
    }

    var body: some View {
        Group {
            if isCompact {
                // iPhone: note list, drill into the editor.
                NavigationStack {
                    listPane
                        .navigationTitle("Notes")
                        .navigationDestination(item: $selectedNote) { note in
                            NoteEditorHost(note: note)
                                .id(note.id)
                                .inlineNavigationTitle()
                        }
                }
            } else {
                PlatformHSplit {
                    listPane
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    editorPane
                        .frame(minWidth: 380)
                }
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Notes")
        // Editor slash command "Link to note" → show the picker; the choice
        // goes back to the editor bridge as an insertNoteLink notification.
        .onReceive(NotificationCenter.default.publisher(for: .hyperviewRequestNoteLink)) { _ in
            showingNoteLinkPicker = true
        }
        // A hyperview://note/<uuid> link was clicked in the editor.
        .onReceive(NotificationCenter.default.publisher(for: .hyperviewOpenNote)) { notification in
            guard let id = notification.userInfo?["id"] as? UUID,
                  let target = notes.first(where: { $0.id == id }) else { return }
            if selectedFolder != nil, target.folder?.id != selectedFolder?.id {
                selectedFolder = nil
            }
            selectedNote = target
        }
        .alert("Rename Folder", isPresented: .init(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("Folder name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if let renamingFolder, !trimmed.isEmpty {
                    renamingFolder.name = trimmed
                    try? context.save()
                }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .sheet(isPresented: $showingNoteLinkPicker) {
            NoteLinkPicker(notes: notes.filter { !$0.isArchived && !$0.isTrashed && $0.id != selectedNote?.id }) { note in
                NotificationCenter.default.post(
                    name: .hyperviewInsertNoteLink,
                    object: nil,
                    userInfo: [
                        "href": "hyperview://note/\(note.id.uuidString)",
                        "text": note.title.isEmpty ? "Untitled" : note.title,
                    ]
                )
            }
        }
        // iOS "Link to file": the editor asks, we present the document picker.
        .onReceive(NotificationCenter.default.publisher(for: .hyperviewRequestFileLink)) { _ in
            showingFileImporter = true
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            FileLinkBookmarks.save(url)
            NotificationCenter.default.post(
                name: .hyperviewInsertNoteLink,
                object: nil,
                userInfo: ["href": url.absoluteString, "text": url.lastPathComponent]
            )
        }
        // iOS: a clicked file link previews with Quick Look.
        .onReceive(NotificationCenter.default.publisher(for: .hyperviewOpenFileLink)) { notification in
            guard let href = notification.userInfo?["href"] as? String else { return }
            previewURL = FileLinkBookmarks.resolve(href)
        }
        .quickLookPreview($previewURL)
    }

    // MARK: List pane

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Notes").font(Theme.Font.cardTitle)
                Spacer()
                Button(action: addFolder) { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("New Folder")
                Button(action: addNote) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("New Note")
            }
            .padding(Theme.Spacing.md)

            List(selection: $selectedNote) {
                Section("Folders") {
                    folderRow(nil, label: "All Notes", systemImage: "tray.full")
                    ForEach(flattenedFolders, id: \.folder.id) { entry in
                        folderRow(entry.folder, label: entry.folder.name, systemImage: "folder", emoji: entry.folder.emoji)
                            .padding(.leading, CGFloat(entry.depth) * 14)
                    }
                }
                if !allTags.isEmpty {
                    Section("Tags") {
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
                }
                if !trashedNotes.isEmpty {
                    Section {
                        Button {
                            showingTrash.toggle()
                            if showingTrash { selectedFolder = nil; selectedTagID = nil }
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "trash")
                                Text("Recently Deleted")
                                Spacer()
                                Text("\(trashedNotes.count)")
                                    .font(Theme.Font.cardCaption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(showingTrash ? Theme.Palette.primary.softFill(0.12) : Color.clear)
                    }
                }
                Section {
                    ForEach(visibleNotes) { note in
                        noteRow(note).tag(note)
                    }
                } header: {
                    HStack {
                        Text(sectionTitle)
                        if showingTrash {
                            Spacer()
                            Button("Empty") {
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

    private var sectionTitle: String {
        if showingTrash { return "Recently Deleted" }
        return selectedFolder?.name ?? "All Notes"
    }

    /// The folder tree flattened depth-first (indentation = depth).
    private var flattenedFolders: [(folder: Folder, depth: Int)] {
        func children(of parentID: UUID?) -> [Folder] {
            folders.filter { $0.parentFolderID == parentID }
        }
        var result: [(Folder, Int)] = []
        func walk(_ parentID: UUID?, depth: Int) {
            guard depth < 8 else { return } // cycle guard
            for folder in children(of: parentID) {
                result.append((folder, depth))
                walk(folder.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        // Orphans (parent deleted elsewhere) still show, at top level.
        let seen = Set(result.map(\.0.id))
        for folder in folders where !seen.contains(folder.id) {
            result.append((folder, 0))
        }
        return result.map { (folder: $0.0, depth: $0.1) }
    }

    /// Folders that may become `folder`'s parent (not itself, not a descendant).
    private func validParents(for folder: Folder) -> [Folder] {
        var descendants = Set<UUID>()
        func mark(_ id: UUID) {
            descendants.insert(id)
            for child in folders where child.parentFolderID == id {
                mark(child.id)
            }
        }
        mark(folder.id)
        return folders.filter { !descendants.contains($0.id) }
    }

    private func folderRow(_ folder: Folder?, label: String, systemImage: String, emoji: String? = nil) -> some View {
        Button {
            selectedFolder = folder
            showingTrash = false
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                if let emoji { Text(emoji) } else { Image(systemName: systemImage) }
                Text(label).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            (!showingTrash && selectedFolder?.id == folder?.id)
                ? Theme.Palette.primary.opacity(0.12)
                : Color.clear
        )
        .contextMenu {
            if let folder {
                Button("Rename…") {
                    renameText = folder.name
                    renamingFolder = folder
                }
                Button("New Subfolder") {
                    let child = store.createFolder(parent: folder)
                    try? context.save()
                    selectedFolder = child
                }
                Menu("Move To") {
                    if folder.parentFolderID != nil {
                        Button("Top Level") {
                            folder.parentFolderID = nil
                            try? context.save()
                        }
                    }
                    ForEach(validParents(for: folder)) { parent in
                        Button(parent.name) {
                            folder.parentFolderID = parent.id
                            try? context.save()
                        }
                    }
                }
                Divider()
                Button("Delete Folder", role: .destructive) {
                    deleteFolder(folder)
                }
            }
        }
    }

    /// Deleting a folder re-parents its subfolders to its parent; its notes
    /// fall back to All Notes (relationship nullifies, §4.1).
    private func deleteFolder(_ folder: Folder) {
        for child in folders where child.parentFolderID == folder.id {
            child.parentFolderID = folder.parentFolderID
        }
        if selectedFolder?.id == folder.id { selectedFolder = nil }
        context.delete(folder)
        try? context.save()
    }

    private func noteRow(_ note: Note) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(note.emoji ?? "📝")
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(Theme.Font.cardBody)
                        .lineLimit(1)
                    TagDots(kind: TagKind.note, key: note.id.uuidString)
                }
                Text(subtitle(for: note))
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .contextMenu {
            if note.isTrashed {
                Button("Put Back") { restore(note) }
                Divider()
                Button("Delete Permanently", role: .destructive) { deleteForever(note) }
            } else {
                TagMenu(kind: TagKind.note, key: note.id.uuidString)
                Button(PinStore.isPinned(note: note.id) ? "Unpin from Dashboard" : "Pin to Dashboard") {
                    PinStore.toggle(note: note.id)
                }
                Divider()
                Button("Delete", role: .destructive) { delete(note) }
            }
        }
        // Swipe is the phone idiom; a context menu is a long-press away.
        .swipeActions(edge: .trailing) {
            if note.isTrashed {
                Button("Delete", role: .destructive) { deleteForever(note) }
                Button("Put Back") { restore(note) }
                    .tint(Theme.Palette.primary)
            } else {
                Button("Delete", role: .destructive) { delete(note) }
            }
        }
    }

    /// Trashed notes say WHEN they were deleted — that's the thing you're
    /// looking for in a trash, not when you last edited them.
    private func subtitle(for note: Note) -> String {
        if let deletedAt = note.deletedAt {
            return "Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return note.modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Editor pane

    @ViewBuilder
    private var editorPane: some View {
        if let selectedNote {
            NoteEditorHost(note: selectedNote)
                .id(selectedNote.id)
        } else {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "note.text")
                    .font(.system(size: 42))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Select or create a note")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Button("New Note", action: addNote)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func addNote() {
        let note = store.createNote(folder: selectedFolder)
        try? context.save()
        selectedNote = note
    }

    private func addFolder() {
        let folder = store.createFolder()
        try? context.save()
        selectedFolder = folder
    }

    /// Move to Recently Deleted (reversible).
    private func delete(_ note: Note) {
        if selectedNote?.id == note.id { selectedNote = nil }
        store.delete(note)
        try? context.save()
    }

    private func restore(_ note: Note) {
        store.restore(note, folders: folders)
        try? context.save()
        if trashedNotes.isEmpty { showingTrash = false }
    }

    private func deleteForever(_ note: Note) {
        if selectedNote?.id == note.id { selectedNote = nil }
        store.deletePermanently(note)
        try? context.save()
        if trashedNotes.isEmpty { showingTrash = false }
    }
}

/// "Link to note" picker: searchable list of notes; choosing one posts the
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
                TextField("Search notes…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if let first = filtered.first { pick(first) }
                    }
            }
            .padding(Theme.Spacing.md)

            Divider().overlay(Theme.Palette.separator)

            if filtered.isEmpty {
                EmptyStateLine(text: "No matching notes.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { note in
                    Button {
                        pick(note)
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(note.emoji ?? "📝")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(note.title.isEmpty ? "Untitled" : note.title)
                                    .font(Theme.Font.cardBody)
                                    .lineLimit(1)
                                if let folder = note.folder {
                                    Text(folder.name)
                                        .font(Theme.Font.cardCaption)
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                }
                            }
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

/// Editor detail: an editable title over the WKWebView block editor.
private struct NoteEditorHost: View {
    @Environment(\.modelContext) private var context
    @Bindable var note: Note
    @State private var showingCheatsheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                TextField("Untitled", text: $note.title)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.dashboardTitle)
                    .onChange(of: note.title) { _, _ in note.modifiedAt = Date() }

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
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.sm)

            NoteEditorWebView(note: note, store: NotesStore(context: context))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.background)
    }
}
