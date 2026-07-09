//
//  TagEditorView.swift
//  Hyperview
//
//  Create or edit a mail tag (name + color). When created from a message's
//  context menu, the new tag is assigned to that message immediately.
//

import SwiftUI
import SwiftData

/// Sheet target: edit an existing tag, or create one (optionally assigning it
/// to the message it was created from).
struct TagEditorTarget: Identifiable {
    let id = UUID()
    var tag: MailTag?
    var assignTo: MailMessage?
}

struct TagEditorView: View {
    let target: TagEditorTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var color: Color = Theme.Palette.primary

    private var isNew: Bool { target.tag == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(isNew ? "New Tag" : "Edit Tag")
                .font(Theme.Font.cardTitle)

            HStack(spacing: Theme.Spacing.md) {
                TextField("Tag name", text: $name)
                    .textFieldStyle(.roundedBorder)
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                Text(name.isEmpty ? "Tag" : name)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(color)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(color.opacity(0.12), in: Capsule())
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button(isNew ? "Create" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.primary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 360)
        .background(Theme.Palette.background)
        .onAppear {
            if let tag = target.tag {
                name = tag.name
                color = Color(hexString: tag.colorHex) ?? Theme.Palette.primary
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let hex = color.hexRGB ?? ""
        if let tag = target.tag {
            tag.name = trimmed
            tag.colorHex = hex
        } else {
            let tag = MailTag(name: trimmed, colorHex: hex)
            context.insert(tag)
            if let message = target.assignTo, let header = message.messageID, !header.isEmpty {
                context.insert(MailTagAssignment(tagID: tag.id, messageIDHeader: header))
            }
        }
        try? context.save()
        dismiss()
    }
}
