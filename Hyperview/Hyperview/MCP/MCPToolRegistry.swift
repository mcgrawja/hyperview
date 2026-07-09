//
//  MCPToolRegistry.swift
//  Hyperview
//
//  §7 — the v1 MCP tool inventory. Every public broker verb gets a tool; the
//  registry is transport-agnostic (today: local HTTP shim → Node stdio bridge →
//  Claude Desktop; later: the in-app API client reuses the same registry).
//
//  Safety defaults (§7): read-heavy; mail sending is DRAFT-ONLY; deletes are
//  not exposed. Every invocation is audit-logged.
//

import Foundation

/// One tool: metadata for tools/list plus its JSON Schema.
nonisolated struct MCPTool: Sendable {
    let name: String
    let description: String
    /// JSON Schema (object) for the tool's arguments.
    let schema: [String: MCPValue]

    static func object(_ properties: [String: MCPValue], required: [String] = []) -> [String: MCPValue] {
        var out: [String: MCPValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty { out["required"] = .array(required.map(MCPValue.string)) }
        return out
    }

    static func prop(_ type: String, _ description: String) -> MCPValue {
        .object(["type": .string(type), "description": .string(description)])
    }
}

/// A tiny JSON value tree (Sendable, unlike [String: Any]).
nonisolated indirect enum MCPValue: Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: MCPValue])
    case array([MCPValue])

    var jsonObject: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues(\.jsonObject)
        case .array(let a): return a.map(\.jsonObject)
        }
    }
}

nonisolated enum MCPToolRegistry {
    static let tools: [MCPTool] = [
        // MARK: Notes (NotesStore)
        MCPTool(
            name: "notes_search",
            description: "Search Hyperview notes by title and text content. Returns id, title, folder, modified date.",
            schema: MCPTool.object(["query": MCPTool.prop("string", "Text to search for; empty lists recent notes")])
        ),
        MCPTool(
            name: "notes_get",
            description: "Get one note's full plain-text content by id.",
            schema: MCPTool.object(["id": MCPTool.prop("string", "Note UUID from notes_search")], required: ["id"])
        ),
        MCPTool(
            name: "notes_create",
            description: "Create a new note. Content lines become paragraph blocks; lines starting with '- ' become bullets.",
            schema: MCPTool.object([
                "title": MCPTool.prop("string", "Note title"),
                "content": MCPTool.prop("string", "Optional body text"),
            ], required: ["title"])
        ),
        MCPTool(
            name: "notes_append_blocks",
            description: "Append text to an existing note (each line becomes a block).",
            schema: MCPTool.object([
                "id": MCPTool.prop("string", "Note UUID"),
                "content": MCPTool.prop("string", "Text to append"),
            ], required: ["id", "content"])
        ),
        MCPTool(
            name: "notes_update_block",
            description: "Replace the text of one block by block id (ids come from notes_get).",
            schema: MCPTool.object([
                "block_id": MCPTool.prop("string", "Block UUID"),
                "content": MCPTool.prop("string", "New text"),
            ], required: ["block_id", "content"])
        ),
        MCPTool(
            name: "notes_toggle_todo",
            description: "Toggle a todo block's checked state by block id.",
            schema: MCPTool.object(["block_id": MCPTool.prop("string", "Block UUID")], required: ["block_id"])
        ),

        // MARK: Calendar (EventKitBroker)
        MCPTool(
            name: "calendar_today",
            description: "Today's calendar events.",
            schema: MCPTool.object([:])
        ),
        MCPTool(
            name: "calendar_query",
            description: "Calendar events in a date range (ISO 8601), optionally filtered by title text.",
            schema: MCPTool.object([
                "start": MCPTool.prop("string", "ISO 8601 start"),
                "end": MCPTool.prop("string", "ISO 8601 end"),
                "search": MCPTool.prop("string", "Optional title filter"),
            ], required: ["start", "end"])
        ),
        MCPTool(
            name: "calendar_create_event",
            description: "Create a calendar event.",
            schema: MCPTool.object([
                "title": MCPTool.prop("string", "Event title"),
                "start": MCPTool.prop("string", "ISO 8601 start"),
                "end": MCPTool.prop("string", "ISO 8601 end"),
                "all_day": MCPTool.prop("boolean", "All-day event (default false)"),
                "notes": MCPTool.prop("string", "Optional notes"),
            ], required: ["title", "start", "end"])
        ),

        // MARK: Reminders (EventKitBroker)
        MCPTool(
            name: "reminders_due",
            description: "Incomplete reminders due within N days (default 7).",
            schema: MCPTool.object(["days": MCPTool.prop("number", "Window in days")])
        ),
        MCPTool(
            name: "reminders_create",
            description: "Create a reminder.",
            schema: MCPTool.object([
                "title": MCPTool.prop("string", "Reminder title"),
                "due": MCPTool.prop("string", "Optional ISO 8601 due date"),
                "notes": MCPTool.prop("string", "Optional notes"),
            ], required: ["title"])
        ),
        MCPTool(
            name: "reminders_complete",
            description: "Mark a reminder complete by id (from reminders_due).",
            schema: MCPTool.object(["id": MCPTool.prop("string", "Reminder identifier")], required: ["id"])
        ),

        // MARK: Mail (MailService — cache + live IMAP)
        MCPTool(
            name: "mail_unread",
            description: "Unread messages across all accounts (from the local cache; call mail_sync first for freshness).",
            schema: MCPTool.object(["limit": MCPTool.prop("number", "Max results (default 25)")])
        ),
        MCPTool(
            name: "mail_sync",
            description: "Sync the inbox of every account from the mail servers, then return new-message counts.",
            schema: MCPTool.object([:])
        ),
        MCPTool(
            name: "mail_search",
            description: "Search a mailbox on the server (defaults to INBOX of every account).",
            schema: MCPTool.object([
                "query": MCPTool.prop("string", "Search text"),
                "account": MCPTool.prop("string", "Optional account email to limit to"),
            ], required: ["query"])
        ),
        MCPTool(
            name: "mail_get_message",
            description: "Fetch one message's body text by account email, mailbox path, and uid (from mail_unread/mail_search results).",
            schema: MCPTool.object([
                "account": MCPTool.prop("string", "Account email"),
                "mailbox": MCPTool.prop("string", "Mailbox path, e.g. INBOX"),
                "uid": MCPTool.prop("number", "Message UID"),
            ], required: ["account", "mailbox", "uid"])
        ),
        MCPTool(
            name: "mail_draft",
            description: "Compose a draft reply/message. DRAFT ONLY — Hyperview never sends via MCP; the user reviews and sends in-app.",
            schema: MCPTool.object([
                "account": MCPTool.prop("string", "From account email"),
                "to": MCPTool.prop("string", "Recipient(s), comma separated"),
                "subject": MCPTool.prop("string", "Subject"),
                "body": MCPTool.prop("string", "Body text"),
            ], required: ["to", "subject", "body"])
        ),

        // MARK: Contacts (ContactsBroker)
        MCPTool(
            name: "contacts_search",
            description: "Search contacts by name.",
            schema: MCPTool.object(["query": MCPTool.prop("string", "Name to search")], required: ["query"])
        ),
        MCPTool(
            name: "contacts_get",
            description: "Get one contact by identifier.",
            schema: MCPTool.object(["id": MCPTool.prop("string", "Contact identifier")], required: ["id"])
        ),

        // MARK: Photos (PhotoBroker)
        MCPTool(
            name: "photos_recent_metadata",
            description: "Metadata (dates, favorites, dimensions) for photos from the last N days (default 7). No pixels.",
            schema: MCPTool.object(["days": MCPTool.prop("number", "Window in days")])
        ),

        // MARK: Composite
        MCPTool(
            name: "dashboard_briefing",
            description: "Cross-module 'what needs my attention': today's events, due reminders, unread mail counts.",
            schema: MCPTool.object([:])
        ),
    ]

    /// tools/list payload for the bridge.
    static func listJSON() -> Data {
        let tools = tools.map { tool -> [String: Any] in
            [
                "name": tool.name,
                "description": tool.description,
                "inputSchema": MCPValue.object(tool.schema).jsonObject,
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: ["tools": tools])) ?? Data()
    }
}
