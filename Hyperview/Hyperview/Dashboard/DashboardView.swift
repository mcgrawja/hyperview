//
//  DashboardView.swift
//  Hyperview
//
//  The unified dashboard (§1). A responsive grid of module cards, each a
//  consumer of a broker. Phase 1 ships Calendar, Reminders, and Contacts;
//  Photos (Phase 3), Mail (Phase 4), and the Claude panel (Phase 5) slot into
//  the same grid.
//

import SwiftUI

struct DashboardView: View {
    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 460), spacing: Theme.Spacing.lg)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.lg) {
                    CalendarCard()
                    RemindersCard()
                    PhotosCard()
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Palette.background)
        .navigationTitle("Dashboard")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(greeting)
                .font(Theme.Font.dashboardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(Date().formatted(date: .complete, time: .omitted))
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello"
        }
    }
}

#Preview {
    DashboardView()
}
