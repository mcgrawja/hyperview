//
//  DatabaseCalendarView.swift
//  Unifyr
//
//  Round 4: the calendar view of a database — a month grid placing rows by a
//  date property (the view's `datePropertyID`, else the first date column).
//  Click a row chip to open its page; ‹ › walk months; rows without a date
//  simply don't appear (the table view is where undated rows live).
//

import SwiftUI
import SwiftData

struct DatabaseCalendarView: View {
    let note: Note
    let properties: [DBProperty]
    let rows: [DBRow]
    let values: [UUID: [UUID: DBCellValue]]
    let dateProperty: DBProperty?
    let openRow: (DBRow) -> Void

    @Environment(\.modelContext) private var context
    /// First day of the displayed month.
    @State private var monthAnchor: Date = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()

    private var store: DatabaseStore { DatabaseStore(context: context) }
    private var titleProperty: DBProperty? { store.titleProperty(among: properties) }
    private var calendar: Calendar { Calendar.current }

    var body: some View {
        if let dateProperty {
            grid(dateProperty)
        } else {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Calendar view needs a Date property.")
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button("Add a Date Property") {
                    store.addProperty(to: note, kind: .date, name: "Date")
                    try? context.save()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Month grid

    private func grid(_ dateProperty: DBProperty) -> some View {
        // "yyyy-MM-dd" string per row — string keys avoid timezone drift
        // (DBCellValue dates are civil dates).
        let byDay: [String: [DBRow]] = Dictionary(grouping: rows.filter {
            values[$0.id]?[dateProperty.id]?.date != nil
        }, by: { values[$0.id]![dateProperty.id]!.date! })

        return VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                Text(monthAnchor.formatted(.dateTime.month(.wide).year()))
                    .font(Theme.Font.cardTitle)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                Button("Today") {
                    monthAnchor = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
                }
                .buttonStyle(.plain)
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.primary)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.sm)

            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, Theme.Spacing.xs)

            GeometryReader { geo in
                let days = monthDays
                let weeks = days.count / 7
                VStack(spacing: 0) {
                    ForEach(0..<weeks, id: \.self) { week in
                        Divider().overlay(Theme.Palette.separator)
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { column in
                                dayCell(days[week * 7 + column], byDay: byDay)
                                    .frame(width: geo.size.width / 7, height: max(60, (geo.size.height - 1) / CGFloat(weeks)), alignment: .topLeading)
                            }
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date?, byDay: [String: [DBRow]]) -> some View {
        Group {
            if let day {
                let key = Self.dayKey(day)
                let isToday = calendar.isDateInToday(day)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(isToday ? Theme.Palette.textOnAccent : Theme.Palette.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isToday ? Theme.Palette.primary : .clear, in: Capsule())
                    ForEach((byDay[key] ?? []).prefix(3)) { row in
                        Button {
                            openRow(row)
                        } label: {
                            Text(store.rowTitle(row.id, titleProperty: titleProperty))
                                .font(Theme.Font.cardCaption)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.Palette.primary.softFill(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                    if let extra = byDay[key]?.count, extra > 3 {
                        Text("+\(extra - 3)")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(3)
            } else {
                Color.clear
            }
        }
    }

    // MARK: Date math

    /// The month's day slots padded to full weeks (nil = another month's slot).
    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let dayCount = calendar.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var slots: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            slots.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        while slots.count % 7 != 0 { slots.append(nil) }
        return slots
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func step(_ direction: Int) {
        monthAnchor = calendar.date(byAdding: .month, value: direction, to: monthAnchor) ?? monthAnchor
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
