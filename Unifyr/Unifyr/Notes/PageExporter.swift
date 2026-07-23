//
//  PageExporter.swift
//  Unifyr
//
//  Round 5: export a page as Markdown, a database as CSV, and import CSV
//  rows into a database. Pure text transforms — testable without UI.
//

import Foundation
import SwiftData

@MainActor
enum PageExporter {

    // MARK: Markdown

    /// The page as Markdown. Inline marks flatten to plain text (v1); every
    /// block kind gets a sensible line form.
    static func markdown(for note: Note, store: NotesStore) -> String {
        let document = store.loadDocument(note)
        var lines: [String] = ["# \(note.title.isEmpty ? "Untitled" : note.title)", ""]
        for node in document.content ?? [] {
            lines.append(contentsOf: markdownLines(node))
        }
        // Collapse trailing blank runs.
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func text(_ node: PMNode) -> String {
        EditorIntegrations.plainText(of: node)
    }

    private static func markdownLines(_ node: PMNode) -> [String] {
        switch node.type {
        case "paragraph":
            return [text(node), ""]
        case "heading":
            let level = node.attrs?["level"]?.intValue ?? 1
            return ["\(String(repeating: "#", count: min(6, level + 1))) \(text(node))", ""]
        case "bulletList", "orderedList", "taskList":
            var out: [String] = []
            for (index, item) in (node.content ?? []).enumerated() {
                let body = text(item).trimmingCharacters(in: .whitespacesAndNewlines)
                switch node.type {
                case "orderedList": out.append("\(index + 1). \(body)")
                case "taskList":
                    let checked = item.attrs?["checked"]?.boolValue ?? false
                    out.append("- [\(checked ? "x" : " ")] \(body)")
                default: out.append("- \(body)")
                }
            }
            out.append("")
            return out
        case "blockquote":
            return ["> \(text(node))", ""]
        case "codeBlock":
            let language = node.attrs?["language"]?.stringValue ?? ""
            return ["```\(language)", text(node), "```", ""]
        case "horizontalRule":
            return ["---", ""]
        case "callout":
            let emoji = node.attrs?["emoji"]?.stringValue ?? "💡"
            return ["> \(emoji) \(text(node))", ""]
        case "toggle":
            var out: [String] = []
            for child in node.content ?? [] {
                if child.type == "toggleSummary" {
                    out.append("**\(text(child))**")
                } else {
                    for grandchild in child.content ?? [] {
                        out.append(contentsOf: markdownLines(grandchild).map { $0.isEmpty ? "" : "  \($0)" })
                    }
                }
            }
            out.append("")
            return out
        case "columnList":
            return (node.content ?? []).flatMap { column in
                (column.content ?? []).flatMap(markdownLines)
            }
        case "table":
            var out: [String] = []
            for (rowIndex, row) in (node.content ?? []).enumerated() {
                let cells = (row.content ?? []).map { text($0).replacingOccurrences(of: "|", with: "\\|") }
                out.append("| " + cells.joined(separator: " | ") + " |")
                if rowIndex == 0 {
                    out.append("|" + Array(repeating: " --- |", count: cells.count).joined())
                }
            }
            out.append("")
            return out
        case "image":
            let src = node.attrs?["src"]?.stringValue ?? ""
            let alt = node.attrs?["alt"]?.stringValue ?? "image"
            return ["![\(alt)](\(src))", ""]
        case "bookmark":
            let url = node.attrs?["url"]?.stringValue ?? ""
            let title = node.attrs?["title"]?.stringValue ?? url
            return ["[\(title)](\(url))", ""]
        case "subpage", "pageembed":
            return ["[[\(node.attrs?["title"]?.stringValue ?? "Untitled")]]", ""]
        case "dbembed":
            return ["[database: \(node.attrs?["title"]?.stringValue ?? "Untitled")]", ""]
        case "agenda":
            return [] // live block; nothing durable to export
        default:
            let body = text(node)
            return body.isEmpty ? [] : [body, ""]
        }
    }

    // MARK: CSV export

    /// The database as RFC-4180-ish CSV: header = column names, cells =
    /// display strings (what the table shows).
    static func csv(databaseID: UUID, store: DatabaseStore) -> String {
        let properties = store.fetchProperties(databaseNoteID: databaseID)
        let rows = store.fetchRows(databaseNoteID: databaseID)
        var lines = [properties.map { escapeCSV($0.name) }.joined(separator: ",")]
        for row in rows {
            let cells = properties.map { property in
                escapeCSV(store.displayText(store.value(rowID: row.id, propertyID: property.id), property: property))
            }
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func escapeCSV(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: CSV import

    /// Quote-aware CSV parser (commas/newlines/escaped quotes in fields).
    nonisolated static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character? = nil

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty: inQuotes = true
                case ",": endField()
                case "\n": endRow()
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Import CSV into a database: header row maps to columns by name
    /// (case-insensitive); unknown headers become new text columns; values go
    /// through the forgiving name-based coercer (selects by option name,
    /// created as needed). Returns (rows imported, columns created).
    @discardableResult
    static func importCSV(_ text: String, into note: Note, store: DatabaseStore) -> (rows: Int, newColumns: Int) {
        let parsed = parseCSV(text)
        guard parsed.count > 1 else { return (0, 0) }
        let headers = parsed[0]

        var columns: [DBProperty?] = []
        var created = 0
        for header in headers {
            let name = header.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                columns.append(nil)
                continue
            }
            let existing = store.fetchProperties(databaseNoteID: note.id)
                .first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            if let existing {
                columns.append(existing)
            } else {
                columns.append(store.addProperty(to: note, kind: .text, name: name))
                created += 1
            }
        }

        var imported = 0
        for values in parsed.dropFirst().prefix(2000) {
            let row = store.addRow(to: note)
            for (index, value) in values.enumerated() where index < columns.count {
                guard let property = columns[index], !value.isEmpty else { continue }
                store.setValue(
                    store.toolCellValue(value, property: property),
                    rowID: row.id,
                    propertyID: property.id,
                    in: note
                )
            }
            imported += 1
        }
        try? store.context.save()
        return (imported, created)
    }
}
