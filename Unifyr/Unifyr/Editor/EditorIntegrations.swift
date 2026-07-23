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
