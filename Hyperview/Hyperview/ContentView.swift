//
//  ContentView.swift
//  Hyperview
//
//  App shell: a sidebar of modules + a detail area. Phase 1 lights up the
//  Dashboard; later phases (Notes, Mail, Photos, Claude) attach to the same
//  navigation. Future modules appear as disabled rows so the roadmap is legible
//  in the UI itself.
//

import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarItem = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarItem.available) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
                Section("Coming soon") {
                    ForEach(SidebarItem.upcoming) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .selectionDisabled()
                }
            }
            .navigationTitle("Hyperview")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch selection {
            case .dashboard:
                DashboardView()
            case .notes:
                NotesView()
            case .contacts:
                ContactsView()
            case .mail:
                MailView()
            case .photos:
                PhotosView()
            case .claude:
                ClaudeView()
            default:
                ComingSoonView(item: selection)
            }
        }
    }
}

/// Sidebar entries. `phase` documents where each lands in the build order (§9).
enum SidebarItem: String, Identifiable, CaseIterable {
    case dashboard
    case notes
    case contacts
    case mail
    case photos
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .notes: return "Notes"
        case .contacts: return "Contacts"
        case .mail: return "Mail"
        case .photos: return "Photos"
        case .claude: return "Claude"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .notes: return "note.text"
        case .contacts: return "person.2"
        case .mail: return "envelope"
        case .photos: return "photo.on.rectangle"
        case .claude: return "sparkles"
        }
    }

    static var available: [SidebarItem] { [.dashboard, .notes, .mail, .photos, .contacts, .claude] }
    static var upcoming: [SidebarItem] { [] }
}

private struct ComingSoonView: View {
    let item: SidebarItem

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: item.systemImage)
                .font(.system(size: 48))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("\(item.title) is coming soon.")
                .font(Theme.Font.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background)
        .navigationTitle(item.title)
    }
}

#Preview {
    ContentView()
}
