//
//  DriveView.swift
//  Hyperview
//
//  Finder-lite file manager: user-added locations in a sidebar (security-
//  scoped, persistent), breadcrumb navigation, a file list with icons/size/
//  date, and the everyday Finder verbs — open, reveal, rename, new folder,
//  duplicate, move to trash. Finder tags on files are read and shown as color
//  dots (they're real Finder tags, visible in Apple's apps).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct DriveView: View {
    @State private var locations = DriveLocations()
    @State private var currentFolder: URL?
    @State private var items: [DriveItem] = []
    @State private var selection: URL?
    @State private var renamingItem: DriveItem?
    @State private var renameText = ""
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var errorText: String?
    @AppStorage("drive.showPreview") private var showPreview = true
    @AppStorage("drive.previewWidth") private var previewWidth = 300.0
    @State private var previewDragBase: Double?

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                sidebar
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 280)
                browser
                    .frame(minWidth: 420)
            }
            // Sibling pane (not an HSplitView child): appears/disappears
            // immediately when toggled; width adjustable via the drag handle.
            if showPreview {
                previewResizeHandle
                Group {
                    if let selection, let item = items.first(where: { $0.url == selection }) {
                        DrivePreviewPane(item: item, onOpen: { open(item) })
                            .id(item.url)
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
        .background(Theme.Palette.background)
        .navigationTitle("Drive")
        .toolbar {
            ToolbarItem {
                Button {
                    locations.addLocation()
                } label: {
                    Label("Add Location", systemImage: "folder.badge.plus")
                }
                .help("Add a folder to browse")
            }
            ToolbarItem {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(currentFolder == nil)
            }
            ToolbarItem {
                Button {
                    newFolderName = ""
                    creatingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus.fill")
                }
                .help("New Folder here")
                .disabled(currentFolder == nil)
            }
            ToolbarItem {
                Toggle(isOn: $showPreview) {
                    Image(systemName: "sidebar.right")
                }
                .help(showPreview ? "Hide Preview" : "Show Preview")
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
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            )
    }

    // MARK: Sidebar

    private var sidebar: some View {
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
                    Button("Add Location…") { locations.addLocation() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Palette.primary)
                }
                .padding(Theme.Spacing.md)
            }
            List {
                ForEach(locations.roots, id: \.self) { root in
                    Button {
                        navigate(to: root)
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
                        isInside(root) ? Theme.Palette.primary.opacity(0.12) : Color.clear
                    )
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                        Button("Remove from Drive", role: .destructive) {
                            if isInside(root) {
                                currentFolder = nil
                                items = []
                            }
                            locations.remove(root)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Theme.Palette.surface)
    }

    private func isInside(_ root: URL) -> Bool {
        guard let currentFolder else { return false }
        return currentFolder.path == root.path || currentFolder.path.hasPrefix(root.path + "/")
    }

    // MARK: Browser

    @ViewBuilder
    private var browser: some View {
        if let currentFolder {
            VStack(spacing: 0) {
                breadcrumbs(for: currentFolder)
                Divider().overlay(Theme.Palette.separator)
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
                    fileList
                }
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

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(items) { item in
                DriveRow(item: item)
                    .tag(item.url)
                    .contentShape(Rectangle())
                    // Simultaneous so single-click still selects the row (a
                    // plain double-click gesture swallowed selection clicks).
                    .simultaneousGesture(TapGesture(count: 2).onEnded { open(item) })
                    .simultaneousGesture(TapGesture().onEnded { selection = item.url })
                    .contextMenu { rowMenu(item) }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            if let selection, let item = items.first(where: { $0.url == selection }) {
                trash(item)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: DriveItem) -> some View {
        Button(item.isDirectory ? "Open" : "Open with Default App") { open(item) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        Button("Rename…") {
            renameText = item.name
            renamingItem = item
        }
        Button("Duplicate") { duplicate(item) }
        TagMenu(kind: TagKind.file, key: item.url.path)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        }
        Divider()
        Button("Move to Trash", role: .destructive) { trash(item) }
    }

    // MARK: Actions

    private func navigate(to folder: URL) {
        currentFolder = folder
        selection = nil
        reload()
    }

    private func reload() {
        errorText = nil
        guard let currentFolder else { return }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: currentFolder,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            items = urls.map(DriveItem.init(url:)).sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch {
            items = []
            errorText = "Couldn't read this folder."
        }
    }

    private func open(_ item: DriveItem) {
        if item.isDirectory {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
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
        guard !trimmed.isEmpty, let currentFolder else { return }
        let folder = currentFolder.appendingPathComponent(trimmed)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            reload()
        } catch {
            errorText = "Couldn't create the folder."
        }
    }
}

// MARK: - Items & rows

/// One directory entry with the metadata the list shows.
struct DriveItem: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int?
    let modified: Date?

    var id: URL { url }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
        self.isDirectory = values?.isDirectory ?? false
        self.size = values?.fileSize
        self.modified = values?.contentModificationDate
    }
}

/// Right-side preview: Quick Look rendering (works for images, PDFs, video
/// frames, documents…), inline text for plain-text files, plus metadata.
private struct DrivePreviewPane: View {
    let item: DriveItem
    let onOpen: () -> Void

    @State private var thumbnail: NSImage?
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
                        Text(kindDescription)
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
                        TagDots(kind: TagKind.file, key: item.url.path)
                    }
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity)
            }
            HStack {
                Button("Open", action: onOpen)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            }
            .padding(.bottom, Theme.Spacing.md)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.Palette.surface)
        .task { await loadPreview() }
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
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 96, height: 96)
        }
    }

    private var kindDescription: String {
        if item.isDirectory { return "Folder" }
        let type = UTType(filenameExtension: item.url.pathExtension)
        return type?.localizedDescription ?? (item.url.pathExtension.isEmpty ? "File" : item.url.pathExtension.uppercased())
    }

    private func loadPreview() async {
        guard !item.isDirectory else { return }
        // Small plain-text files render as text; everything else via Quick Look.
        if let type = UTType(filenameExtension: item.url.pathExtension),
           type.conforms(to: .text) || type.conforms(to: .sourceCode),
           let size = item.size, size < 200_000,
           let data = try? Data(contentsOf: item.url),
           let string = String(data: data, encoding: .utf8) {
            textPreview = String(string.prefix(4000))
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 512, height: 512),
            scale: 2,
            representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = representation.nsImage
        }
    }
}

private struct DriveRow: View {
    let item: DriveItem

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            Text(item.name)
                .font(Theme.Font.cardBody)
                .lineLimit(1)
            TagDots(kind: TagKind.file, key: item.url.path)
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
