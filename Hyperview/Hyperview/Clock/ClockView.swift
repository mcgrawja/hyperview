//
//  ClockView.swift
//  Hyperview
//
//  Clock module: Stopwatch, Timer, and Alarm. On iOS/iPadOS this replaces the
//  Messages tab (Messages is Mac-only). Timer and Alarm fire through Hyperview's
//  notification hub (kind .clock), so they alert even when the app is in the
//  background — consistent with Hyperview being the single alert source.
//

import SwiftUI

struct ClockView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case stopwatch = "Stopwatch"
        case timer = "Timer"
        case alarm = "Alarm"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .stopwatch: return "stopwatch"
            case .timer: return "timer"
            case .alarm: return "alarm"
            }
        }
    }

    @State private var tab: Tab = .stopwatch

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(Theme.Spacing.md)

            Divider().overlay(Theme.Palette.separator)

            switch tab {
            case .stopwatch: StopwatchView()
            case .timer: TimerView()
            case .alarm: AlarmView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background)
        .navigationTitle("Clock")
    }

    /// mm:ss.cc for stopwatch, h:mm:ss for timer/alarm durations.
    static func formatStopwatch(_ interval: TimeInterval) -> String {
        let total = max(0, interval)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let centis = Int((total - floor(total)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, centis)
    }

    static func formatCountdown(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Stopwatch

private struct StopwatchView: View {
    @State private var running = false
    /// Accumulated seconds from prior runs, plus the current run measured from
    /// `startedAt` (a monotonic-ish reference captured on start).
    @State private var accumulated: TimeInterval = 0
    @State private var startedAt: Date?
    @State private var laps: [TimeInterval] = []

    private func elapsed(_ now: Date) -> TimeInterval {
        accumulated + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            TimelineView(.animation(minimumInterval: 0.03, paused: !running)) { context in
                Text(ClockView.formatStopwatch(elapsed(context.date)))
                    .font(.system(size: 64, weight: .light, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.numericText())
            }
            .padding(.top, Theme.Spacing.xl)

            HStack(spacing: Theme.Spacing.lg) {
                Button(running ? "Lap" : "Reset") {
                    if running {
                        laps.insert(elapsed(Date()), at: 0)
                    } else {
                        accumulated = 0
                        laps = []
                    }
                }
                .buttonStyle(ClockButtonStyle(tint: Theme.Palette.surfaceRaised, fg: Theme.Palette.textPrimary))
                .disabled(!running && accumulated == 0)

                Button(running ? "Stop" : "Start") {
                    if running {
                        accumulated = elapsed(Date())
                        startedAt = nil
                    } else {
                        startedAt = Date()
                    }
                    running.toggle()
                }
                .buttonStyle(ClockButtonStyle(
                    tint: running ? Theme.Palette.danger : Theme.Palette.primary,
                    fg: Theme.Palette.textOnAccent
                ))
            }

            if !laps.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(laps.enumerated()), id: \.offset) { index, lap in
                            HStack {
                                Text("Lap \(laps.count - index)")
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                Spacer()
                                Text(ClockView.formatStopwatch(lap))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                            }
                            .padding(.vertical, Theme.Spacing.xs)
                            .padding(.horizontal, Theme.Spacing.lg)
                            Divider().overlay(Theme.Palette.separator)
                        }
                    }
                }
                .frame(maxWidth: 360)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Timer

private struct TimerView: View {
    @AppStorage("clock.timer.hours") private var hours = 0
    @AppStorage("clock.timer.minutes") private var minutes = 5
    @AppStorage("clock.timer.seconds") private var seconds = 0

    @State private var endDate: Date?
    @State private var running = false
    private let identifier = "clock-timer"

    private var configuredSeconds: TimeInterval {
        TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            if running, let endDate {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let remaining = endDate.timeIntervalSince(context.date)
                    Text(ClockView.formatCountdown(remaining))
                        .font(.system(size: 64, weight: .light, design: .monospaced))
                        .foregroundStyle(remaining <= 10 ? Theme.Palette.danger : Theme.Palette.textPrimary)
                        .onChange(of: remaining <= 0) { _, done in
                            if done { finish() }
                        }
                }
                .padding(.top, Theme.Spacing.xl)
            } else {
                wheels
                    .padding(.top, Theme.Spacing.lg)
            }

            Button(running ? "Cancel" : "Start") {
                if running {
                    cancel()
                } else {
                    start()
                }
            }
            .buttonStyle(ClockButtonStyle(
                tint: running ? Theme.Palette.danger : Theme.Palette.primary,
                fg: Theme.Palette.textOnAccent
            ))
            .disabled(!running && configuredSeconds == 0)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var wheels: some View {
        #if os(iOS)
        // iOS has real wheel pickers — the native way to set a duration.
        HStack(spacing: 0) {
            wheel("hours", range: 0...23, selection: $hours)
            wheel("min", range: 0...59, selection: $minutes)
            wheel("sec", range: 0...59, selection: $seconds)
        }
        .frame(height: 170)
        #else
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            field("hours", range: 0...23, selection: $hours)
            colon
            field("min", range: 0...59, selection: $minutes)
            colon
            field("sec", range: 0...59, selection: $seconds)
        }
        #endif
    }

    #if os(iOS)
    private func wheel(_ label: String, range: ClosedRange<Int>, selection: Binding<Int>) -> some View {
        VStack(spacing: 2) {
            Picker(label, selection: selection) {
                ForEach(Array(range), id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            Text(label)
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
    #endif

    #if os(macOS)
    private var colon: some View {
        Text(":")
            .font(.system(size: 40, weight: .light, design: .monospaced))
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.bottom, 18)
    }

    /// A large tappable number with an attached stepper — the macOS-native
    /// stand-in for iOS's time wheels.
    private func field(_ label: String, range: ClosedRange<Int>, selection: Binding<Int>) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(String(format: "%02d", selection.wrappedValue))
                .font(.system(size: 44, weight: .light, design: .monospaced))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(minWidth: 64)
                .contentTransition(.numericText())
            Stepper(label, value: selection, in: range)
                .labelsHidden()
            Text(label)
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
    #endif

    private func start() {
        let duration = configuredSeconds
        guard duration > 0 else { return }
        endDate = Date().addingTimeInterval(duration)
        running = true
        NotificationService.shared.scheduleInterval(
            kind: .clock,
            identifier: identifier,
            title: "Timer",
            body: "Time's up.",
            after: duration
        )
    }

    private func cancel() {
        running = false
        endDate = nil
        NotificationService.shared.cancel(identifier: identifier)
    }

    private func finish() {
        // The scheduled notification already fired; just reset the UI.
        running = false
        endDate = nil
    }
}

// MARK: - Alarm

private struct AlarmItem: Codable, Identifiable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var label: String
    var enabled: Bool
    var repeatsDaily: Bool

    var timeString: String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let date = Calendar.current.date(from: comps) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct AlarmView: View {
    @State private var alarms: [AlarmItem] = AlarmStore.load()
    @State private var editing: AlarmItem?
    @State private var showingEditor = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Alarms")
                    .font(Theme.Font.cardTitle)
                Spacer()
                Button {
                    editing = AlarmItem(hour: 7, minute: 0, label: "Alarm", enabled: true, repeatsDaily: true)
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .padding(Theme.Spacing.lg)

            Divider().overlay(Theme.Palette.separator)

            if alarms.isEmpty {
                EmptyStateLine(text: "No alarms. Tap ＋ to add one.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($alarms) { $alarm in
                        HStack(spacing: Theme.Spacing.md) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(alarm.timeString)
                                    .font(.system(size: 30, weight: .light, design: .rounded))
                                    .foregroundStyle(alarm.enabled ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                                Text(alarm.label + (alarm.repeatsDaily ? " · Daily" : " · Once"))
                                    .font(Theme.Font.cardCaption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: $alarm.enabled)
                                .labelsHidden()
                                .onChange(of: alarm.enabled) { _, _ in apply() }
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editing = alarm
                            showingEditor = true
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                AlarmStore.cancel(alarm)
                                alarms.removeAll { $0.id == alarm.id }
                                AlarmStore.save(alarms)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $showingEditor) {
            if let editing {
                AlarmEditor(alarm: editing) { updated in
                    if let index = alarms.firstIndex(where: { $0.id == updated.id }) {
                        alarms[index] = updated
                    } else {
                        alarms.append(updated)
                    }
                    apply()
                }
            }
        }
    }

    private func apply() {
        AlarmStore.save(alarms)
        for alarm in alarms { AlarmStore.reschedule(alarm) }
    }
}

private struct AlarmEditor: View {
    @State var alarm: AlarmItem
    let onSave: (AlarmItem) -> Void
    @Environment(\.dismiss) private var dismiss

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents(); comps.hour = alarm.hour; comps.minute = alarm.minute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: $0)
                alarm.hour = comps.hour ?? 0
                alarm.minute = comps.minute ?? 0
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Alarm").font(Theme.Font.cardTitle)
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                .platformFieldDatePicker()
            TextField("Label", text: $alarm.label).textFieldStyle(.roundedBorder)
            Toggle("Repeat daily", isOn: $alarm.repeatsDaily)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    alarm.enabled = true
                    onSave(alarm)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 340)
        .background(Theme.Palette.background)
    }
}

private enum AlarmStore {
    private static let key = "clock.alarms"

    static func load() -> [AlarmItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([AlarmItem].self, from: data) else { return [] }
        return items.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    static func save(_ alarms: [AlarmItem]) {
        if let data = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func reschedule(_ alarm: AlarmItem) {
        let id = "clock-alarm-\(alarm.id.uuidString)"
        NotificationService.shared.cancel(identifier: id)
        guard alarm.enabled else { return }
        var comps = DateComponents(); comps.hour = alarm.hour; comps.minute = alarm.minute
        // Next occurrence of hour:minute today or tomorrow.
        let fire = Calendar.current.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) ?? Date()
        NotificationService.shared.schedule(
            kind: .clock,
            identifier: id,
            title: alarm.label.isEmpty ? "Alarm" : alarm.label,
            body: alarm.timeString,
            at: fire,
            repeatsDaily: alarm.repeatsDaily
        )
    }

    static func cancel(_ alarm: AlarmItem) {
        NotificationService.shared.cancel(identifier: "clock-alarm-\(alarm.id.uuidString)")
    }
}

// MARK: - Shared button style

private struct ClockButtonStyle: ButtonStyle {
    let tint: Color
    let fg: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(fg)
            .frame(width: 96, height: 96)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1), in: Circle())
    }
}
