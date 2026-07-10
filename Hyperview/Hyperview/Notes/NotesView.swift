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

struct NotesView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Folder.sortKey) private var folders: [Folder]
    @Query(sort: \Note.sortKey) private var notes: [Note]

    @State private var selectedFolder: Folder?
    @State private var selectedNote: Note?
    @State private var showingNoteLinkPicker = false

    private var store: NotesStore { NotesStore(context: context) }

    private var visibleNotes: [Note] {
        notes.filter { note in
            !note.isArchived && (selectedFolder == nil || note.folder?.id == selectedFolder?.id)
        }
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            editorPane
                .frame(minWidth: 380)
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
        .sheet(isPresented: $showingNoteLinkPicker) {
            NoteLinkPicker(notes: notes.filter { !$0.isArchived && $0.id != selectedNote?.id }) { note in
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
                    ForEach(folders) { folder in
                        folderRow(folder, label: folder.name, systemImage: "folder", emoji: folder.emoji)
                    }
                }
                Section(selectedFolder?.name ?? "All Notes") {
                    ForEach(visibleNotes) { note in
                        noteRow(note).tag(note)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Theme.Palette.surface)
    }

    private func folderRow(_ folder: Folder?, label: String, systemImage: String, emoji: String? = nil) -> some View {
        Button {
            selectedFolder = folder
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
            selectedFolder?.id == folder?.id ? Theme.Palette.primary.opacity(0.12) : Color.clear
        )
    }

    private func noteRow(_ note: Note) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(note.emoji ?? "📝")
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(Theme.Font.cardBody)
                    .lineLimit(1)
                Text(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .contextMenu {
            Button("Delete", role: .destructive) { delete(note) }
        }
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

    private func delete(_ note: Note) {
        if selectedNote?.id == note.id { selectedNote = nil }
        store.delete(note)
        try? context.save()
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
