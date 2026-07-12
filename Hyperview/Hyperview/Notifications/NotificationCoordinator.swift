//
//  NotificationCoordinator.swift
//  Hyperview
//
//  Drives Hyperview's notification hub from a single periodic loop: schedules
//  reminder-due and event-starting notifications for the next day, detects new
//  incoming iMessages, and keeps the Dock badge equal to the total outstanding
//  items (unread mail + unread messages + reminders due/overdue). New-mail
//  notifications come in immediately via MailService's onNewMail closure, wired
//  in the app — not from this poll.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class NotificationCoordinator {
    private let brokers: Brokers
    private let messagesDB: MessagesDatabase?
    private weak var mailService: MailService?

    /// High-water ROWID for new-message detection (0 = not yet baselined).
    private var lastMessageRowID: Int64 = 0
    /// Currently-scheduled time-based identifiers, so dropped items get cancelled.
    private var scheduledReminderIDs: Set<String> = []
    private var scheduledEventIDs: Set<String> = []
    /// handle → contact name cache for message notifications.
    private var nameIndex: [String: String] = [:]
    private var nameIndexLoaded = false

    private(set) var remindersDue = 0

    init(brokers: Brokers, messagesDB: MessagesDatabase?, mailService: MailService?) {
        self.brokers = brokers
        self.messagesDB = messagesDB
        self.mailService = mailService
    }

    /// One poll tick. Called ~every 30s from the app shell.
    func tick() async {
        await scheduleTimeBased()
        await checkMessages()
        updateBadge()
    }

    // MARK: Reminders + events → scheduled notifications

    private func scheduleTimeBased() async {
        let auth = brokers.eventKit.remindersAuthorization
        guard auth == .authorized || auth == .limited else { return }

        // Reminders due within the next 24h (and not completed).
        let now = Date()
        let horizon = now.addingTimeInterval(24 * 3600)
        let reminders = (try? await brokers.eventKit.fetchReminders(BrokerQuery(includeCompleted: false))) ?? []

        // Badge count of reminders due: overdue + due by end of today.
        let endOfToday = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        remindersDue = reminders.filter { ($0.dueDate ?? .distantFuture) < endOfToday }.count

        var desiredReminderIDs = Set<String>()
        for reminder in reminders {
            guard let due = reminder.dueDate, due > now, due <= horizon else { continue }
            let id = "rem-\(reminder.id)"
            desiredReminderIDs.insert(id)
            NotificationService.shared.schedule(
                kind: .reminder,
                identifier: id,
                title: "Reminder",
                body: reminder.title,
                at: due,
                userInfo: ["id": reminder.id]
            )
        }
        for stale in scheduledReminderIDs.subtracting(desiredReminderIDs) {
            NotificationService.shared.cancel(identifier: stale)
        }
        scheduledReminderIDs = desiredReminderIDs

        // Events starting within the next 24h → 10-minute heads-up.
        guard brokers.eventKit.calendarAuthorization == .authorized
                || brokers.eventKit.calendarAuthorization == .limited else { return }
        let events = (try? await brokers.eventKit.fetch(BrokerQuery(dateRange: now...horizon))) ?? []
        var desiredEventIDs = Set<String>()
        for event in events where !event.isAllDay {
            let alertAt = event.start.addingTimeInterval(-10 * 60)
            guard alertAt > now else { continue }
            let id = "evt-\(event.id)"
            desiredEventIDs.insert(id)
            NotificationService.shared.schedule(
                kind: .calendar,
                identifier: id,
                title: "In 10 minutes",
                body: event.title + (event.location.map { " · \($0)" } ?? ""),
                at: alertAt,
                userInfo: ["id": event.id]
            )
        }
        for stale in scheduledEventIDs.subtracting(desiredEventIDs) {
            NotificationService.shared.cancel(identifier: stale)
        }
        scheduledEventIDs = desiredEventIDs
    }

    // MARK: New messages → immediate notifications

    private func checkMessages() async {
        guard let messagesDB else { return }
        let result = await messagesDB.newIncoming(afterRowID: lastMessageRowID)
        let firstBaseline = lastMessageRowID == 0
        lastMessageRowID = result.latest
        guard !firstBaseline else { return } // don't notify history on first run
        await loadNameIndexIfNeeded()
        for ping in result.pings {
            NotificationService.shared.notify(
                kind: .message,
                title: displayName(for: ping.handle),
                body: ping.text,
                threadKey: ping.handle
            )
        }
    }

    private func loadNameIndexIfNeeded() async {
        guard !nameIndexLoaded else { return }
        nameIndexLoaded = true
        guard brokers.contacts.authorization == .authorized || brokers.contacts.authorization == .limited,
              let contacts = try? await brokers.contacts.fetch(BrokerQuery(limit: 3000)) else { return }
        var index: [String: String] = [:]
        for contact in contacts {
            let name = contact.displayName
            guard name != "No Name" else { continue }
            for email in contact.emailAddresses { index[email.lowercased()] = name }
            for phone in contact.phoneNumbers {
                let digits = phone.filter(\.isNumber)
                if digits.count >= 7 { index[String(digits.suffix(10))] = name }
            }
        }
        nameIndex = index
    }

    private func displayName(for handle: String) -> String {
        if handle.contains("@") { return nameIndex[handle.lowercased()] ?? handle }
        let digits = handle.filter(\.isNumber)
        if digits.count >= 7, let name = nameIndex[String(digits.suffix(10))] { return name }
        return handle.isEmpty ? "New message" : handle
    }

    // MARK: Dock badge

    private func updateBadge() {
        let mailUnread = mailService?.totalUnread ?? 0
        NotificationService.shared.setBadge(mailUnread + cachedMessagesUnread + remindersDue)
    }

    /// Fed from the shell's existing messages-unread poll (avoids a 2nd query).
    var cachedMessagesUnread = 0

    /// Fed from the shell after computing due reminders.
    func setRemindersDue(_ count: Int) { remindersDue = count }
}
