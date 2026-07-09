//
//  MarkdownCheatsheet.swift
//  Hyperview
//
//  Reference popover for the editor's markdown shortcuts (the TipTap StarterKit
//  input rules Hyperview enables). Surfaced from a button in the note editor so
//  the "muscle-memory" shortcuts (§5) are discoverable.
//

import SwiftUI

struct MarkdownCheatsheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header

            section("Blocks", rows: [
                .init(code: "# ", label: "Heading 1"),
                .init(code: "## ", label: "Heading 2"),
                .init(code: "### ", label: "Heading 3"),
                .init(code: "- ", label: "Bulleted list"),
                .init(code: "1. ", label: "Numbered list"),
                .init(code: "[] ", label: "To-do checklist"),
                .init(code: "> ", label: "Quote"),
                .init(code: "```", label: "Code block"),
                .init(code: "---", label: "Divider"),
            ])

            section("Inline", rows: [
                .init(code: "**text**", label: "Bold"),
                .init(code: "*text*", label: "Italic"),
                .init(code: "~~text~~", label: "Strikethrough"),
                .init(code: "`text`", label: "Inline code"),
            ])

            section("Keys", rows: [
                .init(code: "⌘B", label: "Bold"),
                .init(code: "⌘I", label: "Italic"),
                .init(code: "⏎", label: "New block · exit list when empty"),
                .init(code: "⇧⏎", label: "Line break within a block"),
            ])
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 320)
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
