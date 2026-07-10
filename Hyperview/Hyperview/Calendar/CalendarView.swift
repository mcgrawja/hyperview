//
//  CalendarView.swift
//  Hyperview
//
//  Full calendar module: month grid (event dots colored by calendar) plus the
//  selected day's agenda, with create/delete via EventKitBroker. Fills the gap
//  where only the dashboard card existed.
//

import SwiftUI

struct CalendarView: View {
    @Environment(\.brokers) private var brokers

    @State private var access: ModuleAccess = .needsPermission
    @State private var monthAnchor = Date()
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var events: [EventSnapshot] = []
    @State private var composing = false

    private let calendar = Calendar.current

    var body: some View {
        Group {
            switch access {
            case .needsPermission:
                VStack {
                    ConnectPrompt(moduleName: "Calendar", systemImage: "calendar", accent: Theme.Palette.primary) {
                        await connect()
                    }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 380)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .blocked:
                VStack { BlockedPrompt(moduleName: "Calendar") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                content
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Calendar")
        .task { await start() }
        .sheet(isPresented: $composing) {
            EventComposerView(defaultDate: selectedDate) {
                Task { await loadMonth() }
            }
        }
    }

    // MARK: Layout

    private var content: some View {
        VStack(spacing: 0) {
            header
            weekdayRow
            monthGrid
            Divider().overlay(Theme.Palette.separator)
            dayAgenda
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(monthAnchor.formatted(.dateTime.month(.wide).year()))
                .font(Theme.Font.dashboardTitle)
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Button("Today") {
                monthAnchor = Date()
                selectedDate = calendar.startOfDay(for: Date())
                Task { await loadMonth() }
            }
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            Button {
                composing = true
            } label: {
                Label("New Event", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.primary)
        }
        .padding(Theme.Spacing.lg)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(calendar.veryShortWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(Theme.Font.cardCaption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xs)
    }

    private var monthGrid: some View {
        let cells = monthCells()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    DayCell(
                        date: day,
                        isSelected: calendar.isDate(day, inSameDayAs: selectedDate),
                        isToday: calendar.isDateInToday(day),
                        eventColors: eventColors(on: day)
                    ) {
                        selectedDate = day
                    }
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
    }

    private var dayAgenda: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(selectedDate.formatted(date: .complete, time: .omitted))
                    .font(Theme.Font.cardTitle)
                let dayEvents = events(on: selectedDate)
                if dayEvents.isEmpty {
                    EmptyStateLine(text: "Nothing scheduled.")
                } else {
                    ForEach(dayEvents) { event in
                        AgendaRow(event: event)
                            .contextMenu {
                                Button("Delete Event", role: .destructive) {
                                    Task {
                                        try? await brokers.eventKit.deleteEvent(id: event.id)
                                        await loadMonth()
                                    }
                                }
                            }
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 140)
    }

    // MARK: Data

    private func start() async {
        access = ModuleAccess(brokers.eventKit.calendarAuthorization)
        guard access == .ready else { return }
        await loadMonth()
        for await _ in brokers.eventKit.changes() {
            await loadMonth()
        }
    }

    private func connect() async {
        do {
            try await brokers.eventKit.requestAccess()
            access = .ready
            await loadMonth()
        } catch {
            access = ModuleAccess(brokers.eventKit.calendarAuthorization)
        }
    }

    private func loadMonth() async {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return }
        // Pad a week each side so edge days render dots correctly.
        let start = interval.start.addingTimeInterval(-7 * 86_400)
        let end = interval.end.addingTimeInterval(7 * 86_400)
        events = (try? await brokers.eventKit.fetch(BrokerQuery(dateRange: start...end))) ?? []
    }

    private func shiftMonth(_ delta: Int) {
        monthAnchor = calendar.date(byAdding: .month, value: delta, to: monthAnchor) ?? monthAnchor
        Task { await loadMonth() }
    }

    private func monthCells() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: day, to: interval.start))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private func events(on day: Date) -> [EventSnapshot] {
        events
            .filter { calendar.isDate($0.start, inSameDayAs: day) || ($0.isAllDay && calendar.isDate(day, equalTo: $0.start, toGranularity: .day)) }
            .sorted { $0.start < $1.start }
    }

    private func eventColors(on day: Date) -> [Color] {
        let colors = events(on: day).compactMap { $0.calendarColorHex.flatMap { Color(hexString: $0) } }
        return Array(colors.prefix(3))
    }
}

// MARK: - Cells & rows

private struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let eventColors: [Color]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(Theme.Font.cardBody.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Theme.Palette.textOnAccent : (isToday ? Theme.Palette.primary : Theme.Palette.textPrimary))
                HStack(spacing: 3) {
                    ForEach(Array(eventColors.enumerated()), id: \.offset) { _, color in
                        Circle().fill(isSelected ? Theme.Palette.textOnAccent : color).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(isSelected ? Theme.Palette.primary : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(isToday && !isSelected ? Theme.Palette.primary : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AgendaRow: View {
    let event: EventSnapshot

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColorHex.flatMap { Color(hexString: $0) } ?? Theme.Palette.primary)
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(Theme.Font.cardBody.weight(.medium))
                HStack(spacing: Theme.Spacing.xs) {
                    Text(event.isAllDay
                         ? "All day"
                         : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                    if let location = event.location, !location.isEmpty {
                        Text("· \(location)").lineLimit(1)
                    }
                }
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
        }
    }
}

// MARK: - Event composer

struct EventComposerView: View {
    let defaultDate: Date
    var onSaved: () -> Void = {}

    @Environment(\.brokers) private var brokers
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var start: Date
    @State private var durationMinutes = 60
    @State private var calendars: [CalendarSnapshot] = []
    @State private var selectedCalendarID = ""
    @State private var saving = false

    init(defaultDate: Date, onSaved: @escaping () -> Void = {}) {
        self.defaultDate = defaultDate
        self.onSaved = onSaved
        let nineAM = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDate) ?? defaultDate
        _start = State(initialValue: nineAM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("New Event").font(Theme.Font.cardTitle)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            DatePicker("Starts", selection: $start)
            Picker("Duration", selection: $durationMinutes) {
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
                Text("All day").tag(-1)
            }
            if !calendars.isEmpty {
                Picker("Calendar", selection: $selectedCalendarID) {
                    ForEach(calendars) { cal in
                        Text(cal.title).tag(cal.id)
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
                        Text("Create")
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
        .task {
            calendars = (try? await brokers.eventKit.eventCalendars()) ?? []
            let saved = UserDefaults.standard.string(forKey: "mail.eventCalendarID") ?? ""
            if calendars.contains(where: { $0.id == saved }) {
                selectedCalendarID = saved
            } else if let jason = calendars.first(where: { $0.title.caseInsensitiveCompare("Jason") == .orderedSame }) {
                selectedCalendarID = jason.id
            } else {
                selectedCalendarID = calendars.first?.id ?? ""
            }
        }
    }

    private func save() async {
        saving = true
        let isAllDay = durationMinutes == -1
        let dayStart = Calendar.current.startOfDay(for: start)
        let end = isAllDay
            ? Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? start
            : start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        _ = try? await brokers.eventKit.createEvent(
            title: title,
            start: isAllDay ? dayStart : start,
            end: end,
            isAllDay: isAllDay,
            calendarID: selectedCalendarID.isEmpty ? nil : selectedCalendarID
        )
        saving = false
        onSaved()
        dismiss()
    }
}
