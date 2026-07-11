//
//  CalendarView.swift
//  Hyperview
//
//  Apple-Calendar-style calendar module: a sidebar of calendars with
//  visibility toggles, a Day / Week / Month view switcher, hour-grid day and
//  week views (positioned event blocks, overlap columns, live now-line,
//  double-click a slot to create), an Apple-style month grid (event chips,
//  adjacent-month days dimmed, double-click a day to open it), and a full
//  event editor (click any event). All via EventKitBroker.
//

import SwiftUI

// MARK: - View mode

private enum CalendarViewMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Sheet target for creating an event at a specific moment (double-clicked
/// grid slot) or a day's default time.
private struct ComposerTarget: Identifiable {
    let id = UUID()
    let start: Date
    let precise: Bool
}

struct CalendarView: View {
    @Environment(\.brokers) private var brokers

    @State private var access: ModuleAccess = .needsPermission
    @AppStorage("calendar.viewMode") private var modeRaw = CalendarViewMode.month.rawValue
    @State private var anchor = Date()
    @State private var events: [EventSnapshot] = []
    @State private var calendars: [CalendarSnapshot] = []
    @State private var hiddenCalendarIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "calendar.hiddenCalendarIDs") ?? []
    )
    @State private var composer: ComposerTarget?
    @State private var editingEvent: EventSnapshot?
    @AppStorage("calendar.sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("calendar.defaultCalendarID") private var defaultCalendarID = ""

    private let calendar = Calendar.current

    private var mode: CalendarViewMode {
        get { CalendarViewMode(rawValue: modeRaw) ?? .month }
    }

    private var visibleEvents: [EventSnapshot] {
        events.filter { !hiddenCalendarIDs.contains($0.calendarID) }
    }

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
        .sheet(item: $composer) { target in
            EventComposerView(
                defaultDate: target.start,
                preciseStart: target.precise ? target.start : nil
            ) {
                Task { await load() }
            }
        }
        .sheet(item: $editingEvent) { event in
            EventEditorView(event: event) {
                Task { await load() }
            }
        }
    }

    // MARK: Layout

    private var content: some View {
        HStack(spacing: 0) {
            if !sidebarCollapsed {
                sidebar
                    .frame(width: 190)
                Divider().overlay(Theme.Palette.separator)
            }
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.Palette.separator)
                switch mode {
                case .month:
                    MonthGridView(
                        anchor: anchor,
                        events: visibleEvents,
                        onOpenDay: { day in
                            anchor = day
                            modeRaw = CalendarViewMode.day.rawValue
                            Task { await load() }
                        },
                        onNewEvent: { day in composer = ComposerTarget(start: day, precise: false) },
                        onEditEvent: { editingEvent = $0 },
                        onDuplicateEvent: { event in Task { await duplicate(event) } },
                        onDeleteEvent: { event in Task { await delete(event) } }
                    )
                case .week:
                    timeGrid(days: weekDays)
                case .day:
                    timeGrid(days: [calendar.startOfDay(for: anchor)])
                }
            }
        }
    }

    private func timeGrid(days: [Date]) -> some View {
        TimeGridView(
            days: days,
            events: visibleEvents,
            onCreate: { start in composer = ComposerTarget(start: start, precise: true) },
            onEditEvent: { editingEvent = $0 },
            onDuplicateEvent: { event in Task { await duplicate(event) } },
            onDeleteEvent: { event in Task { await delete(event) } },
            onMoveEvent: { event, minuteDelta, dayDelta in
                Task { await move(event, minuteDelta: minuteDelta, dayDelta: dayDelta) }
            }
        )
    }

    // MARK: Event actions

    private func duplicate(_ event: EventSnapshot) async {
        _ = try? await brokers.eventKit.createEvent(
            title: event.title,
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            calendarID: event.calendarID.isEmpty ? nil : event.calendarID
        )
        await load()
    }

    private func delete(_ event: EventSnapshot) async {
        try? await brokers.eventKit.deleteEvent(id: event.id)
        await load()
    }

    private func move(_ event: EventSnapshot, minuteDelta: Int, dayDelta: Int) async {
        let delta = TimeInterval(minuteDelta * 60 + dayDelta * 86_400)
        guard delta != 0 else { return }
        _ = try? await brokers.eventKit.updateEvent(
            id: event.id,
            start: event.start.addingTimeInterval(delta),
            end: event.end.addingTimeInterval(delta)
        )
        await load()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CALENDARS")
                .font(Theme.Font.cardCaption.weight(.semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(Theme.Spacing.md)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(calendars) { cal in
                        calendarToggle(cal)
                    }
                }
                .padding(.horizontal, Theme.Spacing.sm)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.surface)
    }

    private func calendarToggle(_ cal: CalendarSnapshot) -> some View {
        let color = cal.colorHex.flatMap { Color(hexString: $0) } ?? Theme.Palette.primary
        let isVisible = !hiddenCalendarIDs.contains(cal.id)
        return Button {
            if isVisible {
                hiddenCalendarIDs.insert(cal.id)
            } else {
                hiddenCalendarIDs.remove(cal.id)
            }
            UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "calendar.hiddenCalendarIDs")
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: isVisible ? "checkmark.square.fill" : "square")
                    .foregroundStyle(color)
                Text(cal.title)
                    .font(Theme.Font.cardBody)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if cal.id == defaultCalendarID {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .help("Default calendar for new events")
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if cal.id == defaultCalendarID {
                Button("Clear Default Calendar") { defaultCalendarID = "" }
            } else {
                Button("Set as Default Calendar") { defaultCalendarID = cal.id }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { sidebarCollapsed.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(sidebarCollapsed ? "Show Calendars" : "Hide Calendars")
            Text(headerTitle)
                .font(Theme.Font.dashboardTitle)
                .lineLimit(1)
            Spacer()
            Picker("", selection: $modeRaw) {
                ForEach(CalendarViewMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .onChange(of: modeRaw) { _, _ in Task { await load() } }
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Button("Today") {
                anchor = Date()
                Task { await load() }
            }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
            Button {
                composer = ComposerTarget(start: calendar.startOfDay(for: anchor), precise: false)
            } label: {
                Label("New Event", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.primary)
        }
        .padding(Theme.Spacing.md)
    }

    private var headerTitle: String {
        switch mode {
        case .month:
            return anchor.formatted(.dateTime.month(.wide).year())
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchor) else {
                return anchor.formatted(.dateTime.month(.wide).year())
            }
            let end = interval.end.addingTimeInterval(-1)
            let sameMonth = calendar.isDate(interval.start, equalTo: end, toGranularity: .month)
            let left = interval.start.formatted(.dateTime.month(.abbreviated).day())
            let right = sameMonth
                ? end.formatted(.dateTime.day())
                : end.formatted(.dateTime.month(.abbreviated).day())
            return "\(left) – \(right), \(end.formatted(.dateTime.year()))"
        case .day:
            return anchor.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        }
    }

    private var weekDays: [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchor) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    // MARK: Data

    private func start() async {
        access = ModuleAccess(brokers.eventKit.calendarAuthorization)
        guard access == .ready else { return }
        await load()
        for await _ in brokers.eventKit.changes() {
            await load()
        }
    }

    private func connect() async {
        do {
            try await brokers.eventKit.requestAccess()
            access = .ready
            await load()
        } catch {
            access = ModuleAccess(brokers.eventKit.calendarAuthorization)
        }
    }

    private func load() async {
        calendars = (try? await brokers.eventKit.eventCalendars(writableOnly: false)) ?? []
        // Month around the anchor padded a week each side covers every mode
        // (a week or day view straddling a month edge included).
        guard let interval = calendar.dateInterval(of: .month, for: anchor) else { return }
        let start = interval.start.addingTimeInterval(-7 * 86_400)
        let end = interval.end.addingTimeInterval(7 * 86_400)
        events = (try? await brokers.eventKit.fetch(BrokerQuery(dateRange: start...end))) ?? []
    }

    private func shift(_ delta: Int) {
        let component: Calendar.Component
        switch mode {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        anchor = calendar.date(byAdding: component, value: delta, to: anchor) ?? anchor
        Task { await load() }
    }
}

// MARK: - Month grid (Apple style)

private struct MonthGridView: View {
    let anchor: Date
    let events: [EventSnapshot]
    let onOpenDay: (Date) -> Void
    let onNewEvent: (Date) -> Void
    let onEditEvent: (EventSnapshot) -> Void
    let onDuplicateEvent: (EventSnapshot) -> Void
    let onDeleteEvent: (EventSnapshot) -> Void

    private let calendar = Calendar.current

    /// 6 weeks × 7 days covering the anchor's month, aligned to week starts —
    /// adjacent-month days included (rendered dimmed), like Apple Calendar.
    private var gridDays: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchor),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start) else {
            return []
        }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: firstWeek.start) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(calendar.shortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(Theme.Font.cardCaption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.xs)
                }
            }
            Divider().overlay(Theme.Palette.separator)
            GeometryReader { geometry in
                let days = gridDays
                let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
                let rowHeight = geometry.size.height / CGFloat(max(weeks.count, 1))
                VStack(spacing: 0) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 0) {
                            ForEach(week, id: \.self) { day in
                                MonthDayCell(
                                    date: day,
                                    inMonth: calendar.isDate(day, equalTo: anchor, toGranularity: .month),
                                    isToday: calendar.isDateInToday(day),
                                    events: dayEvents(day),
                                    onOpen: { onOpenDay(day) },
                                    onNewEvent: { onNewEvent(day) },
                                    onEditEvent: onEditEvent,
                                    onDuplicateEvent: onDuplicateEvent,
                                    onDeleteEvent: onDeleteEvent
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: rowHeight)
                                .overlay(alignment: .trailing) {
                                    Rectangle().fill(Theme.Palette.separator).frame(width: 0.5)
                                }
                            }
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.Palette.separator).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    private func dayEvents(_ day: Date) -> [EventSnapshot] {
        events
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
    }
}

private struct MonthDayCell: View {
    let date: Date
    let inMonth: Bool
    let isToday: Bool
    let events: [EventSnapshot]
    let onOpen: () -> Void
    let onNewEvent: () -> Void
    let onEditEvent: (EventSnapshot) -> Void
    let onDuplicateEvent: (EventSnapshot) -> Void
    let onDeleteEvent: (EventSnapshot) -> Void

    private var dayNumber: String { "\(Calendar.current.component(.day, from: date))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text(dayNumber)
                    .font(Theme.Font.cardCaption.weight(isToday ? .bold : .medium))
                    .foregroundStyle(
                        isToday
                            ? Theme.Palette.textOnAccent
                            : (inMonth ? Theme.Palette.textPrimary : Theme.Palette.textSecondary.opacity(0.55))
                    )
                    .frame(minWidth: 20, minHeight: 20)
                    .background(isToday ? Theme.Palette.danger : Color.clear, in: Circle())
            }
            .padding(.horizontal, 4)
            .padding(.top, 3)

            ForEach(events.prefix(3)) { event in
                MonthEventChip(event: event, dimmed: !inMonth)
                    .onTapGesture { onEditEvent(event) }
                    .contextMenu {
                        Button("Edit Event…") { onEditEvent(event) }
                        Button("Duplicate Event") { onDuplicateEvent(event) }
                        Divider()
                        Button("Delete Event", role: .destructive) { onDeleteEvent(event) }
                    }
            }
            if events.count > 3 {
                Text("+\(events.count - 3) more")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, 5)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen() }
        .contextMenu {
            Button("New Event on \(date.formatted(.dateTime.month(.abbreviated).day()))…") { onNewEvent() }
            Button("Open in Day View") { onOpen() }
        }
    }
}

private struct MonthEventChip: View {
    let event: EventSnapshot
    let dimmed: Bool

    private var color: Color {
        event.calendarColorHex.flatMap { Color(hexString: $0) } ?? Theme.Palette.primary
    }

    var body: some View {
        HStack(spacing: 3) {
            if event.isAllDay {
                Text(event.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textOnAccent)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(event.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(event.start.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow)).minute()))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(event.isAllDay ? color.opacity(0.85) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        .padding(.horizontal, 3)
        .opacity(dimmed ? 0.45 : 1)
    }
}

// MARK: - Day/Week hour grid

private struct TimeGridView: View {
    let days: [Date]
    let events: [EventSnapshot]
    let onCreate: (Date) -> Void
    let onEditEvent: (EventSnapshot) -> Void
    let onDuplicateEvent: (EventSnapshot) -> Void
    let onDeleteEvent: (EventSnapshot) -> Void
    /// Drag-to-move: (event, minuteDelta snapped to 15, dayDelta).
    let onMoveEvent: (EventSnapshot, Int, Int) -> Void

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 46
    private let gutterWidth: CGFloat = 54

    /// Live drag translations keyed by event id (visual offset until release).
    @State private var dragOffsets: [String: CGSize] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if days.count > 1 { dayHeaderRow }
            allDayRow
            Divider().overlay(Theme.Palette.separator)
            ScrollViewReader { proxy in
                ScrollView {
                    TimelineView(.everyMinute) { context in
                        grid(now: context.date)
                    }
                }
                .onAppear {
                    // Land at 7 AM like Apple Calendar, not midnight.
                    proxy.scrollTo("hour-7", anchor: .top)
                }
            }
        }
    }

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: 1)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 1) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(calendar.isDateInToday(day) ? Theme.Palette.danger : Theme.Palette.textSecondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(Theme.Font.cardBody.weight(calendar.isDateInToday(day) ? .bold : .regular))
                        .foregroundStyle(calendar.isDateInToday(day) ? Theme.Palette.danger : Theme.Palette.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private var allDayRow: some View {
        let anyAllDay = days.contains { !allDayEvents(on: $0).isEmpty }
        if anyAllDay {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: gutterWidth)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 2) {
                        ForEach(allDayEvents(on: day)) { event in
                            AllDayChip(event: event)
                                .onTapGesture { onEditEvent(event) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func grid(now: Date) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Hour gutter
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hourLabel(hour))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: gutterWidth - 8, height: hourHeight, alignment: .topTrailing)
                        .offset(y: -6)
                        .id("hour-\(hour)")
                }
            }
            .frame(width: gutterWidth)

            ForEach(days, id: \.self) { day in
                dayColumn(day, now: now)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.Palette.separator).frame(width: 0.5)
                    }
            }
        }
        .frame(height: hourHeight * 24)
    }

    private func dayColumn(_ day: Date, now: Date) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Hour lines: double-click OR right-click a slot to create there
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: hourHeight)
                            .overlay(alignment: .top) {
                                Rectangle().fill(Theme.Palette.separator.opacity(0.6)).frame(height: 0.5)
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("New Event at \(slotLabel(hour))…") {
                                    if let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) {
                                        onCreate(start)
                                    }
                                }
                            }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    let hour = min(max(Int(location.y / hourHeight), 0), 23)
                    if let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) {
                        onCreate(start)
                    }
                }

                // Events — click to edit, right-click for actions, drag to move
                // (vertical = time in 15-minute snaps, horizontal = day).
                ForEach(layout(timedEvents(on: day), day: day)) { laid in
                    let width = geometry.size.width / CGFloat(laid.cols)
                    let dragOffset = dragOffsets[laid.event.id] ?? .zero
                    EventBlock(event: laid.event)
                        .frame(width: max(width - 3, 20), height: max(laid.height, 22))
                        .offset(
                            x: CGFloat(laid.col) * width + 1.5 + dragOffset.width,
                            y: laid.y + dragOffset.height
                        )
                        .opacity(dragOffset == .zero ? 1 : 0.75)
                        .zIndex(dragOffset == .zero ? 0 : 10)
                        .onTapGesture { onEditEvent(laid.event) }
                        .contextMenu {
                            Button("Edit Event…") { onEditEvent(laid.event) }
                            Button("Duplicate Event") { onDuplicateEvent(laid.event) }
                            Divider()
                            Button("Delete Event", role: .destructive) { onDeleteEvent(laid.event) }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 6)
                                .onChanged { value in
                                    dragOffsets[laid.event.id] = value.translation
                                }
                                .onEnded { value in
                                    dragOffsets[laid.event.id] = nil
                                    let minuteDelta = Int((value.translation.height / hourHeight * 60 / 15).rounded()) * 15
                                    let dayDelta = days.count > 1
                                        ? Int((value.translation.width / geometry.size.width).rounded())
                                        : 0
                                    if minuteDelta != 0 || dayDelta != 0 {
                                        onMoveEvent(laid.event, minuteDelta, dayDelta)
                                    }
                                }
                        )
                }

                // Now line
                if calendar.isDate(now, inSameDayAs: day) {
                    let y = yOffset(of: now, in: day)
                    Rectangle()
                        .fill(Theme.Palette.danger)
                        .frame(height: 1.5)
                        .offset(y: y)
                    Circle()
                        .fill(Theme.Palette.danger)
                        .frame(width: 7, height: 7)
                        .offset(x: -3, y: y - 2.75)
                }
            }
        }
        .frame(height: hourHeight * 24)
        .clipped()
    }

    // MARK: Events & geometry

    private func allDayEvents(on day: Date) -> [EventSnapshot] {
        events.filter { $0.isAllDay && calendar.isDate($0.start, inSameDayAs: day) }
    }

    private func timedEvents(on day: Date) -> [EventSnapshot] {
        events.filter { !$0.isAllDay && calendar.isDate($0.start, inSameDayAs: day) }
    }

    private func yOffset(of date: Date, in day: Date) -> CGFloat {
        let dayStart = calendar.startOfDay(for: day)
        let seconds = date.timeIntervalSince(dayStart)
        return CGFloat(seconds / 3600) * hourHeight
    }

    private struct LaidEvent: Identifiable {
        let event: EventSnapshot
        let y: CGFloat
        let height: CGFloat
        let col: Int
        let cols: Int
        var id: String { event.id }
    }

    /// Overlapping events split the column like Apple Calendar: transitive
    /// overlap clusters share the width; each event takes the first free
    /// sub-column.
    private func layout(_ dayEvents: [EventSnapshot], day: Date) -> [LaidEvent] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let sorted = dayEvents.sorted {
            $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start
        }

        var result: [LaidEvent] = []
        var cluster: [(event: EventSnapshot, col: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let cols = max(columnEnds.count, 1)
            for entry in cluster {
                let start = max(entry.event.start, dayStart)
                let end = min(entry.event.end, dayEnd)
                result.append(LaidEvent(
                    event: entry.event,
                    y: yOffset(of: start, in: day),
                    height: CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight - 2,
                    col: entry.col,
                    cols: cols
                ))
            }
            cluster = []
            columnEnds = []
        }

        for event in sorted {
            if !cluster.isEmpty && event.start >= clusterEnd {
                flush()
                clusterEnd = .distantPast
            }
            let col: Int
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[free] = event.end
                col = free
            } else {
                columnEnds.append(event.end)
                col = columnEnds.count - 1
            }
            cluster.append((event, col))
            clusterEnd = max(clusterEnd, event.end)
        }
        flush()
        return result
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0 else { return "" }
        return slotLabel(hour)
    }

    private func slotLabel(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }
}

private struct EventBlock: View {
    let event: EventSnapshot

    private var color: Color {
        event.calendarColorHex.flatMap { Color(hexString: $0) } ?? Theme.Palette.primary
    }

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }
}

private struct AllDayChip: View {
    let event: EventSnapshot

    private var color: Color {
        event.calendarColorHex.flatMap { Color(hexString: $0) } ?? Theme.Palette.primary
    }

    var body: some View {
        Text(event.title)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.Palette.textOnAccent)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Event editor

/// Full editor for an existing event: title, all-day, start/end, location,
/// notes, calendar (move), delete.
struct EventEditorView: View {
    let event: EventSnapshot
    var onSaved: () -> Void = {}

    @Environment(\.brokers) private var brokers
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var location: String
    @State private var notes: String
    @State private var calendarID: String
    @State private var calendars: [CalendarSnapshot] = []
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var errorText: String?

    init(event: EventSnapshot, onSaved: @escaping () -> Void = {}) {
        self.event = event
        self.onSaved = onSaved
        _title = State(initialValue: event.title)
        _isAllDay = State(initialValue: event.isAllDay)
        _start = State(initialValue: event.start)
        _end = State(initialValue: event.end)
        _location = State(initialValue: event.location ?? "")
        _notes = State(initialValue: event.notes ?? "")
        _calendarID = State(initialValue: event.calendarID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Edit Event").font(Theme.Font.cardTitle)
                Spacer()
                Text(event.calendarTitle)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Location", text: $location).textFieldStyle(.roundedBorder)

            Toggle("All-day", isOn: $isAllDay).toggleStyle(.checkbox)
            DatePicker(
                "Starts",
                selection: $start,
                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
            )
            DatePicker(
                "Ends",
                selection: $end,
                in: start...,
                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
            )

            if !calendars.isEmpty {
                Picker("Calendar", selection: $calendarID) {
                    ForEach(calendars) { cal in
                        Text(cal.title).tag(cal.id)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("NOTES")
                    .font(Theme.Font.cardCaption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextEditor(text: $notes)
                    .font(Theme.Font.cardBody)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }

            if let errorText {
                Text(errorText)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.danger)
            }

            HStack {
                Button("Delete Event…", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.danger)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if saving { ProgressView().controlSize(.small) }
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || saving)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420)
        .background(Theme.Palette.background)
        .task {
            calendars = (try? await brokers.eventKit.eventCalendars()) ?? []
            // A read-only calendar won't be in the writable list; keep the
            // event where it is rather than showing a wrong selection.
            if !calendars.contains(where: { $0.id == calendarID }) {
                calendars.insert(
                    CalendarSnapshot(id: event.calendarID, title: event.calendarTitle, colorHex: event.calendarColorHex),
                    at: 0
                )
            }
        }
        .confirmationDialog("Delete “\(event.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() async {
        saving = true
        do {
            _ = try await brokers.eventKit.updateEvent(
                id: event.id,
                title: title,
                start: start,
                end: max(end, start),
                isAllDay: isAllDay,
                location: location,
                notes: notes,
                calendarID: calendarID == event.calendarID ? nil : calendarID
            )
            saving = false
            onSaved()
            dismiss()
        } catch {
            saving = false
            errorText = "Couldn't save the event."
        }
    }

    private func delete() async {
        do {
            try await brokers.eventKit.deleteEvent(id: event.id)
            onSaved()
            dismiss()
        } catch {
            errorText = "Couldn't delete the event."
        }
    }
}

// MARK: - Event composer

struct EventComposerView: View {
    let defaultDate: Date
    var preciseStart: Date?
    var onSaved: () -> Void = {}

    @Environment(\.brokers) private var brokers
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var start: Date
    @State private var durationMinutes = 60
    @State private var calendars: [CalendarSnapshot] = []
    @State private var selectedCalendarID = ""
    @State private var saving = false

    init(defaultDate: Date, preciseStart: Date? = nil, onSaved: @escaping () -> Void = {}) {
        self.defaultDate = defaultDate
        self.preciseStart = preciseStart
        self.onSaved = onSaved
        // A double-clicked grid slot arrives as a precise start; a plain "New
        // Event" defaults to 9 AM on the given day.
        let nineAM = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDate) ?? defaultDate
        _start = State(initialValue: preciseStart ?? nineAM)
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
            // Priority: the user-chosen default calendar, then the last one
            // used from Mail, then "Jason", then the first available.
            let preferred = UserDefaults.standard.string(forKey: "calendar.defaultCalendarID") ?? ""
            let saved = UserDefaults.standard.string(forKey: "mail.eventCalendarID") ?? ""
            if calendars.contains(where: { $0.id == preferred }) {
                selectedCalendarID = preferred
            } else if calendars.contains(where: { $0.id == saved }) {
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
