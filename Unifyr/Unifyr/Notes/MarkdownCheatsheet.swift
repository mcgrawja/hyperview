//
//  MarkdownCheatsheet.swift
//  Unifyr
//
//  Reference popover for the editor's markdown shortcuts (the TipTap StarterKit
//  input rules Unifyr enables). Surfaced from a button in the note editor so
//  the "muscle-memory" shortcuts (§5) are discoverable.
//

import SwiftUI

struct MarkdownCheatsheet: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header

                section("Type to format", rows: [
                    .init(code: "# ", label: "Heading 1 (##, ### for 2–3)"),
                    .init(code: "- ", label: "Bulleted list"),
                    .init(code: "1. ", label: "Numbered list"),
                    .init(code: "[] ", label: "To-do checklist"),
                    .init(code: "> ", label: "Quote"),
                    .init(code: "```", label: "Code block"),
                    .init(code: "---", label: "Divider"),
                    .init(code: "@", label: "Mention a page (inline link chip)"),
                ])

                section("Inline", rows: [
                    .init(code: "**text**", label: "Bold"),
                    .init(code: "*text*", label: "Italic"),
                    .init(code: "~~text~~", label: "Strikethrough"),
                    .init(code: "`text`", label: "Inline code"),
                ])

                section("Slash commands — blocks", rows: [
                    .init(code: "/toggle", label: "Collapsible block"),
                    .init(code: "/callout", label: "Emoji callout (click emoji to change)"),
                    .init(code: "/code", label: "Code with syntax highlighting"),
                    .init(code: "/image", label: "Insert a picture (or just paste/drop)"),
                    .init(code: "/2 col", label: "Column layout (also /3 columns)"),
                    .init(code: "/table", label: "Simple table · add/delete rows"),
                    .init(code: "/divider", label: "Horizontal rule"),
                ])

                section("Slash commands — pages & data", rows: [
                    .init(code: "/sub-page", label: "Create a page inside this page"),
                    .init(code: "/new data", label: "Create + embed a new database"),
                    .init(code: "/linked", label: "Embed an existing database view"),
                    .init(code: "/link", label: "Link to a note or a file"),
                ])

                section("Keys & mouse", rows: [
                    .init(code: "⌘B · ⌘I", label: "Bold · Italic"),
                    .init(code: "⏎", label: "New block · into toggle body on a summary"),
                    .init(code: "⇧⏎", label: "Line break within a block"),
                    .init(code: "⌘⏎", label: "Fold / unfold the current toggle"),
                    .init(code: "⠿ drag", label: "Hover a block's left edge to move it"),
                    .init(code: "corner", label: "Drag an image's corner dot to resize"),
                    .init(code: "col gap", label: "Drag between columns to resize them"),
                ])
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: 350, height: 520)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "text.badge.checkmark")
                .foregroundStyle(Theme.Palette.primary)
            Text("Markdown Shortcuts")
                .font(Theme.Font.cardTitle)
            Spacer()
        }
    }

    private func section(_ title: String, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title.uppercased())
                .font(Theme.Font.cardCaption.weight(.semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
            ForEach(rows) { row in
                HStack(spacing: Theme.Spacing.md) {
                    Text(row.code)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .frame(width: 96, alignment: .leading)
                    Text(row.label)
                        .font(Theme.Font.cardBody)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    struct Row: Identifiable {
        let id = UUID()
        let code: String
        let label: String
    }
}

#Preview {
    MarkdownCheatsheet()
}
