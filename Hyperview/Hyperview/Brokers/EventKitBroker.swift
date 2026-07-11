//
//  EventKitBroker.swift
//  Hyperview
//
//  §3 / §6 — Calendar + Reminders. One actor owns one EKEventStore. Access is
//  requested lazily, per module, on first open (never at launch): calendar and
//  reminders are distinct TCC prompts, so each has its own request verb.
//
//  Every public verb here is destined to become an MCP tool (§7):
//    fetch / fetchEvents      -> calendar_today, calendar_query
//    createEvent              -> calendar_create_event
//    fetchReminders           -> reminders_due
//    createReminder           -> reminders_create
//    completeReminder         -> reminders_complete
//

import Foundation
import EventKit
import CoreLocation

/// A geofence for a location-based reminder alarm.
nonisolated struct ReminderLocation: Sendable, Hashable, Codable {
    var title: String
    var latitude: Double
    var longitude: Double
    var radius: Double = 100
    /// "enter" (arriving) or "leave" (leaving).
    var proximity: String = "enter"
}

actor EventKitBroker: DataBroker {
    typealias Item = EventSnapshot

    private let store = EKEventStore()

    // MARK: Authorization

    /// Requests full **calendar** access (primary item). Reminders access is a
    /// separate prompt — see `requestRemindersAccess()`.
    func requestAccess() async throws {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw BrokerError.accessDenied }
    }

    func requestRemindersAccess() async throws {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw BrokerError.accessDenied }
    }

    nonisolated var calendarAuthorization: BrokerAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    nonisolated var remindersAuthorization: BrokerAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func map(_ status: EKAuthorizationStatus) -> BrokerAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .authorized
        case .writeOnly: return .limited
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    // MARK: Calendar (DataBroker.Item == EventSnapshot)

    /// `fetch` returns calendar events. Honors `dateRange` (defaults to today)
    /// and `limit`.
    func fetch(_ query: BrokerQuery) async throws -> [EventSnapshot] {
        guard calendarAuthorization == .authorized || calendarAuthorization == .limited else {
            throw BrokerError.accessDenied
        }
        let range = query.dateRange ?? Self.todayRange()
        let predicate = store.predicateForEvents(
            withStart: range.lowerBound,
            end: range.upperBound,
            calendars: nil
        )
        var events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        if let text = query.searchText, !text.isEmpty {
            events = events.filter { ($0.title ?? "").localizedCaseInsensitiveContains(text) }
        }
        if let limit = query.limit { events = Array(events.prefix(limit)) }
        return events.map(Self.snapshot(from:))
    }

    /// Convenience for the dashboard "today" card.
    func fetchTodayEvents() async throws -> [EventSnapshot] {
        try await fetch(BrokerQuery(dateRange: Self.todayRange()))
    }

    /// Event calendars. `writableOnly` (the default) keeps the create/move
    /// pickers honest; pass false for visibility toggles, which also cover
    /// read-only calendars (Birthdays, holidays, subscriptions).
    func eventCalendars(writableOnly: Bool = true) async throws -> [CalendarSnapshot] {
        guard calendarAuthorization == .authorized || calendarAuthorization == .limited else {
            throw BrokerError.accessDenied
        }
        return store.calendars(for: .event)
            .filter { !writableOnly || $0.allowsContentModifications }
            .map { calendar in
                CalendarSnapshot(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    colorHex: calendar.cgColor.flatMap(Self.hexString(from:))
                )
            }
            .sorted { $0.title < $1.title }
    }

    /// Creates an event and returns its snapshot. `calendarID` selects the
    /// target calendar (default calendar when nil/unknown).
    @discardableResult
    func createEvent(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        calendarID: String? = nil
    ) async throws -> EventSnapshot {
        guard calendarAuthorization == .authorized else { throw BrokerError.accessDenied }
        guard end >= start else { throw BrokerError.invalidInput("end must not precede start") }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.location = location
        event.notes = notes
        event.calendar = calendarID.flatMap { store.calendar(withIdentifier: $0) }
            ?? store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
        return Self.snapshot(from: event)
    }

    /// Update an existing event; nil fields are left unchanged.
    @discardableResult
    func updateEvent(
        id: String,
        title: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        isAllDay: Bool? = nil,
        location: String? = nil,
        notes: String? = nil,
        calendarID: String? = nil
    ) async throws -> EventSnapshot {
        guard calendarAuthorization == .authorized else { throw BrokerError.accessDenied }
        guard let event = store.event(withIdentifier: id) else { throw BrokerError.notFound }
        if let title { event.title = title }
        if let start { event.startDate = start }
        if let end { event.endDate = end }
        if let isAllDay { event.isAllDay = isAllDay }
        if let location { event.location = location }
        if let notes { event.notes = notes }
        if let calendarID, let calendar = store.calendar(withIdentifier: calendarID) {
            event.calendar = calendar
        }
        guard event.endDate >= event.startDate else {
            throw BrokerError.invalidInput("end must not precede start")
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
        return Self.snapshot(from: event)
    }

    /// Delete an event (this occurrence only for recurring events).
    func deleteEvent(id: String) async throws {
        guard calendarAuthorization == .authorized else { throw BrokerError.accessDenied }
        guard let event = store.event(withIdentifier: id) else { throw BrokerError.notFound }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
    }

    // MARK: Reminders (domain-specific verbs, §3)

    /// Incomplete reminders due within `dateRange` (or all incomplete if none),
    /// plus completed ones when `includeCompleted` is set.
    func fetchReminders(_ query: BrokerQuery) async throws -> [ReminderSnapshot] {
        guard remindersAuthorization == .authorized || remindersAuthorization == .limited else {
            throw BrokerError.accessDenied
        }
        let predicate: NSPredicate
        if let range = query.dateRange {
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: range.lowerBound,
                ending: range.upperBound,
                calendars: nil
            )
        } else {
            predicate = store.predicateForReminders(in: nil)
        }

        var reminders = try await fetchReminderSnapshots(matching: predicate)
        if !query.includeCompleted {
            reminders = reminders.filter { !$0.isCompleted }
        }
        if let text = query.searchText, !text.isEmpty {
            reminders = reminders.filter { $0.title.localizedCaseInsensitiveContains(text) }
        }
        reminders.sort(by: Self.byDueDate)
        if let limit = query.limit { reminders = Array(reminders.prefix(limit)) }
        return reminders
    }

    /// Dashboard "due" card: incomplete reminders with a due date up to now+window.
    func fetchDueReminders(within window: TimeInterval = 7 * 24 * 60 * 60) async throws -> [ReminderSnapshot] {
        let now = Date()
        return try await fetchReminders(
            BrokerQuery(dateRange: now.addingTimeInterval(-window)...now.addingTimeInterval(window))
        )
    }

    /// The user's reminders lists (all of them — read is useful even for
    /// read-only lists; writes fail per-item if EventKit refuses).
    func reminderLists() async throws -> [CalendarSnapshot] {
        guard remindersAuthorization == .authorized || remindersAuthorization == .limited else {
            throw BrokerError.accessDenied
        }
        return store.calendars(for: .reminder).map { list in
            CalendarSnapshot(
                id: list.calendarIdentifier,
                title: list.title,
                colorHex: list.cgColor.flatMap(Self.hexString(from:))
            )
        }
        .sorted { $0.title < $1.title }
    }

    /// Create a new reminders list in the default reminders source (iCloud
    /// normally), so it syncs like any list made in Apple Reminders.
    @discardableResult
    func createReminderList(title: String) async throws -> CalendarSnapshot {
        guard remindersAuthorization == .authorized else { throw BrokerError.accessDenied }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = title
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw BrokerError.underlying("No reminders account available")
        }
        list.source = source
        do {
            try store.saveCalendar(list, commit: true)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
        return CalendarSnapshot(
            id: list.calendarIdentifier,
            title: list.title,
            colorHex: list.cgColor.flatMap(Self.hexString(from:))
        )
    }

    @discardableResult
    func createReminder(
        title: String,
        dueDate: Date? = nil,
        priority: Int = 0,
        notes: String? = nil,
        listID: String? = nil
    ) async throws -> ReminderSnapshot {
        guard remindersAuthorization == .authorized else { throw BrokerError.accessDenied }
        guard let list = listID.flatMap({ store.calendar(withIdentifier: $0) })
            ?? store.defaultCalendarForNewReminders() else {
            throw BrokerError.underlying("No default reminders list")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        reminder.priority = priority
        reminder.notes = notes
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate
            )
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
        return Self.snapshot(from: reminder)
    }

    /// Marks a reminder complete by identifier.
    func completeReminder(id: String) async throws {
        try await setReminderCompleted(id: id, completed: true)
    }

    /// Restores a completed reminder to incomplete.
    func uncompleteReminder(id: String) async throws {
        try await setReminderCompleted(id: id, completed: false)
    }

    private func setReminderCompleted(id: String, completed: Bool) async throws {
        guard remindersAuthorization == .authorized else { throw BrokerError.accessDenied }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw BrokerError.notFound
        }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
    }

    /// Update an existing reminder; nil fields are left unchanged.
    /// `clearDueDate` removes an existing due date (nil `dueDate` alone means
    /// "unchanged"); `listID` moves the reminder to another list.
    @discardableResult
    func updateReminder(
        id: String,
        title: String? = nil,
        dueDate: Date? = nil,
        clearDueDate: Bool = false,
        notes: String? = nil,
        priority: Int? = nil,
        listID: String? = nil,
        url: String? = nil,
        clearURL: Bool = false,
        location: ReminderLocation? = nil,
        clearLocation: Bool = false
    ) async throws -> ReminderSnapshot {
        guard remindersAuthorization == .authorized else { throw BrokerError.accessDenied }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw BrokerError.notFound
        }
        if let title { reminder.title = title }
        if clearDueDate {
            reminder.dueDateComponents = nil
        } else if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate
            )
        }
        if let notes { reminder.notes = notes }
        if let priority { reminder.priority = priority }
        // List moves are handled AFTER the field save below — EventKit can
        // throw or silently refuse a cross-list save, which previously took
        // the whole update down with it.
        var targetList: EKCalendar?
        if let listID, listID != reminder.calendar?.calendarIdentifier {
            guard let list = store.calendar(withIdentifier: listID) else {
                throw BrokerError.invalidInput("Unknown reminders list")
            }
            targetList = list
        }
        if clearURL {
            reminder.url = nil
        } else if let url, !url.isEmpty {
            reminder.url = URL(string: url)
        }
        if clearLocation || location != nil {
            for alarm in reminder.alarms ?? [] where alarm.structuredLocation != nil {
                reminder.removeAlarm(alarm)
            }
        }
        if let location {
            let structured = EKStructuredLocation(title: location.title)
            structured.geoLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            structured.radius = location.radius
            let alarm = EKAlarm()
            alarm.structuredLocation = structured
            alarm.proximity = location.proximity == "leave" ? .leave : .enter
            reminder.addAlarm(alarm)
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
        guard let targetList else {
            return Self.snapshot(from: reminder)
        }

        // Move: try in-place first (catching failure instead of throwing);
        // verify; fall back to copy-into-target + delete-original, which is
        // the only approach EventKit honors reliably.
        reminder.calendar = targetList
        var movedInPlace = false
        do {
            try store.save(reminder, commit: true)
            store.refreshSourcesIfNecessary()
            let check = store.calendarItem(withIdentifier: id) as? EKReminder
            movedInPlace = check?.calendar?.calendarIdentifier == targetList.calendarIdentifier
        } catch {
            movedInPlace = false
        }
        if movedInPlace {
            return Self.snapshot(from: reminder)
        }

        guard let original = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw BrokerError.notFound
        }
        let copy = EKReminder(eventStore: store)
        copy.title = original.title
        copy.calendar = targetList
        copy.dueDateComponents = original.dueDateComponents
        copy.notes = original.notes
        copy.priority = original.priority
        copy.url = original.url
        copy.isCompleted = original.isCompleted
        for alarm in original.alarms ?? [] {
            if let cloned = alarm.copy() as? EKAlarm {
                copy.addAlarm(cloned)
            }
        }
        do {
            try store.save(copy, commit: true)
            try store.remove(original, commit: true)
        } catch {
            throw BrokerError.underlying("Couldn't move the reminder: \(error.localizedDescription)")
        }
        return Self.snapshot(from: copy)
    }

    /// Delete a reminder.
    func deleteReminder(id: String) async throws {
        guard remindersAuthorization == .authorized else { throw BrokerError.accessDenied }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw BrokerError.notFound
        }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
    }

    // MARK: Change feed

    /// EKEventStoreChanged is store-wide (covers both events and reminders), so
    /// every notification is surfaced as `.reloaded`.
    nonisolated func changes() -> AsyncStream<BrokerChange<EventSnapshot>> {
        AsyncStream { continuation in
            // Token is only ever passed to removeObserver; safe to share.
            nonisolated(unsafe) let token = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield(.reloaded)
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    // MARK: - Helpers

    private static func todayRange() -> ClosedRange<Date> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start...end
    }

    /// Converts to Sendable snapshots inside the completion handler so no
    /// EKReminder (non-Sendable) crosses back to the actor.
    private func fetchReminderSnapshots(matching predicate: NSPredicate) async throws -> [ReminderSnapshot] {
        try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).map(Self.snapshot(from:))
                continuation.resume(returning: snapshots)
            }
        }
    }

    private static func byDueDate(_ a: ReminderSnapshot, _ b: ReminderSnapshot) -> Bool {
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.title < b.title
        }
    }

    private static func snapshot(from event: EKEvent) -> EventSnapshot {
        EventSnapshot(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "(No Title)",
            start: event.startDate ?? Date(),
            end: event.endDate ?? event.startDate ?? Date(),
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            calendarTitle: event.calendar?.title ?? "",
            calendarColorHex: event.calendar?.cgColor.flatMap(hexString(from:)),
            calendarID: event.calendar?.calendarIdentifier ?? ""
        )
    }

    private static func snapshot(from reminder: EKReminder) -> ReminderSnapshot {
        let locationAlarm = reminder.alarms?.first { $0.structuredLocation != nil }
        return ReminderSnapshot(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "(No Title)",
            dueDate: reminder.dueDateComponents?.date,
            isCompleted: reminder.isCompleted,
            priority: reminder.priority,
            notes: reminder.notes,
            listTitle: reminder.calendar?.title ?? "",
            listID: reminder.calendar?.calendarIdentifier ?? "",
            url: reminder.url?.absoluteString,
            locationTitle: locationAlarm?.structuredLocation?.title,
            locationProximity: locationAlarm.map { $0.proximity == .leave ? "leave" : "enter" }
        )
    }

    private static func hexString(from color: CGColor) -> String? {
        guard let components = color.components, components.count >= 3 else { return nil }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
