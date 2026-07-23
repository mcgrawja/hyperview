//
//  EditorIntegrations.swift
//  Unifyr
//
//  Integration round 2: the broker-backed payloads the editor asks for —
//  the universal "@" mention index (contacts, events, reminders alongside
//  pages) and the "/agenda" block's live snapshot. Display strings are
//  formatted HERE so the JS side stays dumb.
//

import Foundation

enum EditorIntegrations {

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Mention sources beyond pages: [{kind, id, title, icon, dateISO?}].
    /// Failures (no TCC grant yet) contribute nothing — mentioning pages
    /// still works.
    static func mentionSourcesJSON(brokers: Brokers) async -> String? {
        var entries: [[String: Any]] = []

        if let contacts = try? await brokers.contacts.fetch(BrokerQuery()) {
            for contact in contacts.prefix(300) {
                let name = "\(contact.givenName) \(contact.familyName)"
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                entries.append(["kind": "contact", "id": contact.id, "title": name, "icon": "👤"])
            }
        }

        let now = Date()
        let range = now.addingTimeInterval(-14 * 86_400)...now.addingTimeInterval(60 * 86_400)
        if let events = try? await brokers.eventKit.fetch(BrokerQuery(searchText: nil, dateRange: range)) {
            for event in events.prefix(150) {
                entries.append([
                    "kind": "event",
                    "id": event.id,
                    "title": "\(event.title) · \(event.start.formatted(date: .abbreviated, time: .omitted))",
                    "icon": "🗓️",
                    "dateISO": iso.string(from: event.start),
                ])
            }
        }

        if let reminders = try? await brokers.eventKit.fetchDueReminders(within: 30 * 86_400) {
            for reminder in reminders.prefix(150) {
                entries.append(["kind": "reminder", "id": reminder.id, "title": reminder.title, "icon": "✅"])
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: entries) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: "/ask" (Claude in the editor, round 3)

    /// The page's plain text (Claude's context for /ask).
    static func plainText(of node: PMNode) -> String {
        if node.type == "text" { return node.text ?? "" }
        let inner = (node.content ?? []).map(plainText(of:)).joined(
            separator: node.type == "doc" ? "\n" : ""
        )
        return inner
    }

    /// Lines → blocks ("- " bullets, "## " headings, else paragraphs) — the
    /// same shape the MCP notes_create importer uses.
    static func blocks(fromText text: String) -> [PMNode] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { return nil }
                if line.hasPrefix("- ") {
                    return PMNode(type: "bulletList", content: [
                        PMNode(type: "listItem", content: [
                            PMNode(type: "paragraph", content: [.text(String(line.dropFirst(2)))]),
                        ]),
                    ])
                }
                if line.hasPrefix("## ") {
                    return PMNode(type: "heading", attrs: ["level": .int(2)], content: [.text(String(line.dropFirst(3)))])
                }
                return PMNode(type: "paragraph", content: [.text(line)])
            }
    }

    /// One-shot /ask completion (BriefingService pattern: raw Messages call,
    /// the user's stored model, no streaming).
    static func askClaude(apiKey: String, prompt: String, pageTitle: String, pageText: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let model = UserDefaults.standard.string(forKey: "claude.model") ?? "claude-sonnet-5"
        let system = """
        You are Claude, helping inside a page of Jason's Unifyr notes. Answer \
        the request using the page content as context. Reply in PLAIN TEXT: \
        short paragraphs, "- " for bullets, "## " for the rare heading. No \
        other markdown. Be concise and directly useful — your answer is \
        appended to the page.
        """
        let userContent = """
        Page title: \(pageTitle.isEmpty ? "Untitled" : pageTitle)

        Page content:
        \(String(pageText.prefix(24_000)))

        Request: \(prompt)
        """
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": system,
            "messages": [["role": "user", "content": userContent]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            throw NSError(domain: "Unifyr", code: 2, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else {
            throw NSError(domain: "Unifyr", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected response"])
        }
        let answer = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !answer.isEmpty else {
            throw NSError(domain: "Unifyr", code: 4, userInfo: [NSLocalizedDescriptionKey: "Empty answer"])
        }
        return answer
    }

    /// "/agenda" snapshot: today's events + reminders due within a week,
    /// pre-formatted. {events:[{id,title,time,dateISO}], reminders:[{id,title,due}]}
    static func agendaJSON(brokers: Brokers, scope: String) async -> String? {
        var events: [[String: Any]] = []
        var reminders: [[String: Any]] = []

        if let today = try? await brokers.eventKit.fetchTodayEvents() {
            for event in today {
                events.append([
                    "id": event.id,
                    "title": event.title,
                    "time": event.isAllDay ? "all-day" : event.start.formatted(date: .omitted, time: .shortened),
                    "dateISO": iso.string(from: event.start),
                ])
            }
        }
        if let due = try? await brokers.eventKit.fetchDueReminders(within: 7 * 86_400) {
            for reminder in due.prefix(20) {
                reminders.append([
                    "id": reminder.id,
                    "title": reminder.title,
                    "due": reminder.dueDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "",
                ])
            }
        }

        let payload: [String: Any] = [
            "scope": scope,
            "date": Date().formatted(date: .complete, time: .omitted),
            "events": events,
            "reminders": reminders,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
