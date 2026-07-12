//
//  TagViews.swift
//  Hyperview
//
//  Reusable universal-tag UI. `TagMenu` goes inside any context menu; it
//  toggles HVTagLink rows for one item. `TagDots` shows an item's tag colors
//  inline. `TagManagerView` (create/rename/recolor/delete) is presented
//  app-wide from ContentView via the .hyperviewShowTagManager notification —
//  context menus can't present sheets themselves.
//
//  All of these read the MAIN (CloudKit) container via \.modelContext — do
//  not use them inside the Mail subtree, which overrides the container (mail
//  keeps its own tag system for now).
//

import SwiftUI
import SwiftData

extension Notification.Name {
    static let hyperviewShowTagManager = Notification.Name("hyperview.showTagManager")
}

/// "Tags ▸" submenu for one item's context menu.
struct TagMenu: View {
    let kind: String
    let key: String

    @Environment(\.modelContext) private var context
    @Query(sort: \HVTag.name) private var tags: [HVTag]
    @Query private var links: [HVTagLink]

    var body: some View {
        Menu("Tags") {
            ForEach(tags) { tag in
                Button {
                    toggle(tag)
                } label: {
                    if isTagged(tag) {
                        Label(tag.name, systemImage: "checkmark")
                    } else {
                        Text(tag.name)
                    }
                }
            }
            if !tags.isEmpty { Divider() }
            Button("Edit Tags…") {
                NotificationCenter.default.post(name: .hyperviewShowTagManager, object: nil)
            }
        }
    }

    private func isTagged(_ tag: HVTag) -> Bool {
        links.contains { $0.tagID == tag.id && $0.itemKind == kind && $0.itemKey == key }
    }

    private func toggle(_ tag: HVTag) {
        let existing = links.filter { $0.tagID == tag.id && $0.itemKind == kind && $0.itemKey == key }
        if existing.isEmpty {
            context.insert(HVTagLink(tagID: tag.id, itemKind: kind, itemKey: key))
        } else {
            for link in existing { context.delete(link) }
        }
        try? context.save()
    }
}

/// Small color dots showing an item's tags inline.
struct TagDots: View {
    let kind: String
    let key: String

    @Query(sort: \HVTag.name) private var tags: [HVTag]
    @Query private var links: [HVTagLink]

    private var itemTags: [HVTag] {
        let ids = Set(links.filter { $0.itemKind == kind && $0.itemKey == key }.compactMap(\.tagID))
        return tags.filter { ids.contains($0.id) }
    }

    var body: some View {
        let visible = itemTags
        if !visible.isEmpty {
            HStack(spacing: 2) {
                ForEach(visible.prefix(4)) { tag in
                    Circle()
                        .fill(Color(hexString: tag.colorHex) ?? Theme.Palette.primary)
                        .frame(width: 7, height: 7)
                        .help(tag.name)
                }
            }
        }
    }
}

/// Create / rename / recolor / delete tags. Deleting a tag removes its links
/// everywhere (the items themselves are untouched).
struct TagManagerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HVTag.name) private var tags: [HVTag]
    @Query private var links: [HVTagLink]

    @State private var newName = ""

    private static let paletteDefaults = [
        "#3E8EF7", "#F2A65A", "#E5624D", "#F5B841", "#8E6EDB", "#4FB3BF", "#7F838C",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tags")
                .font(Theme.Font.cardTitle)
                .padding(Theme.Spacing.lg)
            Text("One tag vocabulary across Notes, Reminders, Calendar, Contacts, and Messages. Tags sync with iCloud (and to iOS later). Files use Finder tags instead — those are visible in Apple's apps.")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.md)

            Divider().overlay(Theme.Palette.separator)

            if tags.isEmpty {
                EmptyStateLine(text: "No tags yet — create one below.")
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(tags) { tag in
                        TagEditorRow(tag: tag, linkCount: linkCount(tag)) {
                            delete(tag)
                        }
                    }
                }
                .listStyle(.plain)
            }

            Divider().overlay(Theme.Palette.separator)

            HStack(spacing: Theme.Spacing.sm) {
                TextField("New tag name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Button("Add", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: 440, height: 420)
        .background(Theme.Palette.background)
    }

    private func linkCount(_ tag: HVTag) -> Int {
        links.count { $0.tagID == tag.id }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              !tags.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        let color = Self.paletteDefaults[tags.count % Self.paletteDefaults.count]
        context.insert(HVTag(name: name, colorHex: color))
        try? context.save()
        newName = ""
    }

    private func delete(_ tag: HVTag) {
        for link in links where link.tagID == tag.id {
            context.delete(link)
        }
        context.delete(tag)
        try? context.save()
    }
}

private struct TagEditorRow: View {
    @Bindable var tag: HVTag
    let linkCount: Int
    let onDelete: () -> Void

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hexString: tag.colorHex) ?? Theme.Palette.primary },
            set: { tag.colorHex = $0.hexRGB ?? tag.colorHex }
        )
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28)
            TextField("Name", text: $tag.name)
                .textFieldStyle(.plain)
                .font(Theme.Font.cardBody)
            Spacer()
            Text("\(linkCount) item\(linkCount == 1 ? "" : "s")")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Delete tag (items keep their content)")
        }
        .padding(.vertical, 2)
    }
}
