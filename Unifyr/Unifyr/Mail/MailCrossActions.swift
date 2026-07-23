//
//  MailCrossActions.swift
//  Unifyr
//
//  Cross-broker actions from an email (§7 spirit — modules composing): create
//  a Reminder, create a Calendar event, add the sender to Contacts. These are
//  the first places Mail drives the EventKit/Contacts brokers, the same verbs
//  the MCP tools will call in Phase 6. TCC access is requested lazily on first
//  use (§6).
//

import SwiftUI
import SwiftData

/// Ellipsis menu shown in the message header.
struct MailActionsMenu: View {
    let message: MailMessage
    let onFeedback: (String) -> Void
    @Binding var eventSheet: EventFromEmailSheet?

    @Environment(\.brokers) private var brokers
    /// The CloudKit notes container — Mail's subtree \.modelContext is the
    /// mail cache, so "Save to Notes" goes through this instead.
    @Environment(\.notesContainer) private var notesContainer

    /// The owning account's email (for MCP tool references in handoffs).
    var accountEmail: String = ""

    var body: some View {
        Menu {
            Button {
                ClaudeHandoff.send(ClaudeHandoff.draftReply(to: message, accountEmail: accountEmail))
            } label: {
                Label("Draft Reply with Claude", systemImage: "sparkles")
            }
            Button {
                ClaudeHandoff.send(ClaudeHandoff.summarize(message, accountEmail: accountEmail))
            } label: {
                Label("Summarize with Claude", systemImage: "sparkles")
            }
            Divider()
            Button {
                Task { await createReminder() }
            } label: {
                Label("Remind Me About This", systemImage: "checklist")
            }
            Button {
                eventSheet = EventFromEmailSheet(message: message)
            } label: {
                Label("Create Calendar Event…", systemImage: "calendar.badge.plus")
            }
            Divider()
            Button {
                saveToNotes()
            } label: {
                Label("Save to Notes", systemImage: "note.text.badge.plus")
            }
            Button {
                Task { await addSenderToContacts() }
            } label: {
                Label("Add Sender to Contacts", systemImage: "person.crop.circle.badge.plus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Actions")
    }

    private func createReminder() async {
        do {
            if brokers.eventKit.remindersAuthorization != .authorized {
                try await brokers.eventKit.requestRemindersAccess()
            }
            try await brokers.eventKit.createReminder(
                title: message.subject,
                notes: reminderNotes
            )
            onFeedback("Reminder created: “\(message.subject)”")
        } catch {
            onFeedback("Couldn't create the reminder — check Reminders access in System Settings.")
        }
    }

    private func addSenderToContacts() async {
        do {
            if brokers.contacts.authorization != .authorized {
                try await brokers.contacts.requestAccess()
            }
            if let existing = try await brokers.contacts.findByEmail(message.fromAddress) {
                onFeedback("\(existing.displayName) is already in Contacts.")
                return
            }
            let (given, family) = Self.splitName(message.fromName)
            let contact = try await brokers.contacts.addContact(
                givenName: given,
                familyName: family,
                email: message.fromAddress
            )
            onFeedback("Added \(contact.displayName) to Contacts.")
        } catch {
            onFeedback("Couldn't add the contact — check Contacts access in System Settings.")
        }
    }

    /// Clip the email into the Notes page tree: a child page of a top-level
    /// "Clippings" page (created on first use), titled by subject, holding a
    /// metadata callout plus the body text.
    private func saveToNotes() {
        guard let notesContainer else {
            onFeedback("Notes storage isn't available.")
            return
        }
        let context = ModelContext(notesContainer)
        let store = NotesStore(context: context)

        // Find-or-create the 📥 Clippings top-level page.
        let clippings: Note
        if let existing = ((try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.parentNoteID == nil && $0.deletedAt == nil && $0.title == "Clippings" }
        ))) ?? []).first {
            clippings = existing
        } else {
            clippings = store.createPage(title: "Clippings")
            clippings.emoji = "📥"
        }

        let page = store.createPage(
            title: message.subject.isEmpty ? "(no subject)" : message.subject,
            parent: clippings
        )
        page.emoji = "✉️"

        let sender = message.fromName.isEmpty ? message.fromAddress : message.fromName
        let meta = "From \(sender) · \(message.date.formatted(date: .abbreviated, time: .shortened)) · \(accountEmail)"
        var blocks: [PMNode] = [
            PMNode(type: "callout", attrs: ["emoji": .string("✉️")], content: [
                PMNode(type: "paragraph", content: [.text(meta)]),
            ]),
        ]
        for line in Self.clipBodyLines(text: message.bodyText, html: message.bodyHTML) {
            // inlineContent gives URLs in the clip live link marks.
            blocks.append(PMNode(type: "paragraph", content: EditorIntegrations.inlineContent(for: line)))
        }
        store.save(PMNode(type: "doc", content: blocks), to: page)
        do {
            try context.save()
            onFeedback("Saved to Notes: Clippings › “\(page.title)”")
        } catch {
            onFeedback("Couldn't save the note.")
        }
    }

    /// Body text for a clipping: prefer the plain part; else strip the HTML
    /// down crudely (tags out, entities in) — a clipping is a record, not a
    /// pixel-perfect render. Capped so a 500-message digest doesn't become a
    /// 500-block note. `nonisolated`: pure, and the tests call it off-main.
    nonisolated static func clipBodyLines(text: String?, html: String?) -> [String] {
        var body = text ?? ""
        if body.isEmpty, let html {
            body = html
                .replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
        }
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Collapse runs of blank lines; cap at 120 paragraphs.
        var out: [String] = []
        for line in lines {
            if line.isEmpty && out.last?.isEmpty != false { continue }
            out.append(line)
            if out.count >= 120 { break }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out
    }

    private var reminderNotes: String {
        "Email from \(message.fromName.isEmpty ? message.fromAddress : message.fromName) — \(message.date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// "Jane Q. Doe" → ("Jane", "Q. Doe"); single token → given name only;
    /// empty → email local-part as the given name.
    static func splitName(_ fullName: String) -> (given: String, family: String) {
        let parts = fullName.split(separator: " ").map(String.init)
        if parts.isEmpty { return ("", "") }
        if parts.count == 1 { return (parts[0], "") }
        return (parts[0], parts.dropFirst().joined(separator: " "))
    }
}

/// Sheet state for "Create Calendar Event…".
struct EventFromEmailSheet: Identifiable {
    let id = UUID()
    let message: MailMessage
}

/// Prefilled event editor: title from the subject, tomorrow morning by default.
struct EventFromEmailView: View {
    let message: MailMessage
    let onFeedback: (String) -> Void

    @Environment(\.brokers) private var brokers
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var start: Date
    @State private var durationMinutes = 60
    @State private var saving = false
    @State private var calendars: [CalendarSnapshot] = []
    @State private var selectedCalendarID = ""
    /// Remembers the last-used calendar; first run prefers one named "Jason".
    @AppStorage("mail.eventCalendarID") private var savedCalendarID = ""

    init(message: MailMessage, onFeedback: @escaping (String) -> Void) {
        self.message = message
        self.onFeedback = onFeedback
        _title = State(initialValue: message.subject)
        let tomorrow9 = Calendar.current.date(
            bySettingHour: 9, minute: 0, second: 0,
            of: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        ) ?? Date()
        _start = State(initialValue: tomorrow9)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("New Event from Email")
                .font(Theme.Font.cardTitle)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            DatePicker("Starts", selection: $start)

            Picker("Duration", selection: $durationMinutes) {
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
                Text("All day").tag(-1)
            }

            if !calendars.isEmpty {
                Picker("Calendar", selection: $selectedCalendarID) {
                    ForEach(calendars) { calendar in
                        HStack(spacing: Theme.Spacing.xs) {
                            Circle()
                                .fill(Color(hexString: calendar.colorHex ?? "") ?? Theme.Palette.primary)
                                .frame(width: 8, height: 8)
                            Text(calendar.title)
                        }
                        .tag(calendar.id)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if saving { ProgressView().controlSize(.small) }
                        Text("Add to Calendar")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.primary)
                .disabled(title.isEmpty || saving)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 380)
        .background(Theme.Palette.background)
        .task { await loadCalendars() }
    }

    private func loadCalendars() async {
        do {
            if brokers.eventKit.calendarAuthorization != .authorized {
                try await brokers.eventKit.requestAccess()
            }
            calendars = try await brokers.eventKit.eventCalendars()
            // Last-used calendar wins; first run prefers one named "Jason";
            // otherwise the first writable calendar.
            if calendars.contains(where: { $0.id == savedCalendarID }) {
                selectedCalendarID = savedCalendarID
            } else if let jason = calendars.first(where: { $0.title.caseInsensitiveCompare("Jason") == .orderedSame }) {
                selectedCalendarID = jason.id
            } else {
                selectedCalendarID = calendars.first?.id ?? ""
            }
        } catch {
            calendars = [] // picker hidden; save() falls back to the default calendar
        }
    }

    private func save() async {
        saving = true
        do {
            if brokers.eventKit.calendarAuthorization != .authorized {
                try await brokers.eventKit.requestAccess()
            }
            let isAllDay = durationMinutes == -1
            let end = isAllDay
                ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start)) ?? start
                : start.addingTimeInterval(TimeInterval(durationMinutes * 60))
            try await brokers.eventKit.createEvent(
                title: title,
                start: isAllDay ? Calendar.current.startOfDay(for: start) : start,
                end: end,
                isAllDay: isAllDay,
                notes: "From email: \(message.fromName.isEmpty ? message.fromAddress : message.fromName)",
                calendarID: selectedCalendarID.isEmpty ? nil : selectedCalendarID
            )
            savedCalendarID = selectedCalendarID
            saving = false
            onFeedback("Event added: “\(title)”")
            dismiss()
        } catch {
            saving = false
            onFeedback("Couldn't create the event — check Calendar access in System Settings.")
            dismiss()
        }
    }
}
