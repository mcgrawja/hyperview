//
//  ContentView.swift
//  Unifyr
//
//  App shell: a sidebar of modules + a detail area. Phase 1 lights up the
//  Dashboard; later phases (Notes, Mail, Photos, Claude) attach to the same
//  navigation. Future modules appear as disabled rows so the roadmap is legible
//  in the UI itself.
//

import SwiftUI

struct ContentView: View {
    // Optional: iOS's List/NavigationSplitView require an optional selection
    // binding (macOS tolerates a non-optional one).
    @State private var selection: SidebarItem? = .dashboard
    @Environment(\.mailService) private var mailService
    #if os(macOS)
    @Environment(\.messagesDB) private var messagesDB
    #endif
    @Environment(\.notificationCoordinator) private var notificationCoordinator
    @State private var messagesUnread = 0
    @State private var showingSearch = false
    @State private var showingTagManager = false

    /// Universal-search navigation: files reveal in Finder; everything else
    /// switches modules, then posts the deep-link once the module has mounted
    /// (its onReceive registers on appear).
    private func handleSearchHit(_ hit: SearchHit) {
        if let revealURL = hit.revealURL {
            PlatformKit.reveal(revealURL)
            return
        }
        selection = hit.module
        if let notification = hit.notification {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(
                    name: notification.name,
                    object: nil,
                    userInfo: notification.userInfo
                )
            }
        }
    }

    private func badgeCount(for item: SidebarItem) -> Int {
        switch item {
        case .mail: return mailService?.totalUnread ?? 0
        case .messages: return messagesUnread
        default: return 0
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarItem.available) { item in
                        Label(item.title, systemImage: item.systemImage)
                            // Serene: the Claude nav item wears the AI accent
                            // (amber) — the one warm element in the sidebar.
                            .foregroundStyle(
                                item == .claude && selection != .claude
                                    ? Theme.Palette.claude
                                    : Color.primary
                            )
                            .badge(badgeCount(for: item))
                            .tag(item)
                    }
                }
                // Only render the header when something is actually queued.
                if !SidebarItem.upcoming.isEmpty {
                    Section("Coming soon") {
                        ForEach(SidebarItem.upcoming) { item in
                            Label(item.title, systemImage: item.systemImage)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .selectionDisabled()
                    }
                }
            }
            .navigationTitle("Unifyr")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            // Messages unread badge — polled (chat.db has no change feed);
            // silently 0 until Full Disk Access is granted.
            .task {
                while !Task.isCancelled {
                    #if os(macOS)
                    messagesUnread = await messagesDB?.unreadCount() ?? 0
                    #endif
                    // Drive the notification hub from the same tick: message
                    // arrivals, reminder/event scheduling, app badge.
                    if let coordinator = notificationCoordinator {
                        coordinator.cachedMessagesUnread = messagesUnread
                        await coordinator.tick()
                    }
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            // Recount the moment a conversation is read in Unifyr, so the
            // badge clears immediately instead of on the next 30s tick.
            .onReceive(NotificationCenter.default.publisher(for: .unifyrMessagesReadLocally)) { _ in
                #if os(macOS)
                Task {
                    messagesUnread = await messagesDB?.unreadCount() ?? 0
                    await notificationCoordinator?.refreshMessagesBadge(unread: messagesUnread)
                }
                #endif
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Search Unifyr (⌘K)")
                }
            }
            .sheet(isPresented: $showingSearch) {
                UniversalSearchView { hit in
                    handleSearchHit(hit)
                }
            }
            // Context menus can't present sheets — the tag manager is
            // app-global, summoned from any module's "Edit Tags…".
            .onReceive(NotificationCenter.default.publisher(for: .unifyrShowTagManager)) { _ in
                showingTagManager = true
            }
            // Dashboard pinned-item rows: switch to the module, then post the
            // module-level open notification once it has mounted.
            .onReceive(NotificationCenter.default.publisher(for: .unifyrRevealNote)) { notification in
                guard let id = notification.userInfo?["id"] as? UUID else { return }
                selection = .notes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: .unifyrOpenNote, object: nil, userInfo: ["id": id])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .unifyrRevealReminder)) { notification in
                guard let id = notification.userInfo?["id"] as? String else { return }
                selection = .reminders
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: .unifyrOpenReminder, object: nil, userInfo: ["id": id])
                }
            }
            // Tapping a Unifyr notification opens its module.
            .onReceive(NotificationCenter.default.publisher(for: .unifyrOpenModule)) { notification in
                guard let raw = notification.userInfo?["module"] as? String,
                      let item = SidebarItem(rawValue: raw),
                      SidebarItem.available.contains(item) else { return }
                selection = item
            }
            .sheet(isPresented: $showingTagManager) {
                TagManagerView()
            }
        } detail: {
            // nil (nothing selected, possible on iPhone's stacked nav) shows
            // the Dashboard.
            switch selection ?? .dashboard {
            case .dashboard:
                DashboardView()
            case .calendar:
                CalendarView()
            case .reminders:
                RemindersView()
            case .notes:
                NotesView()
            case .drive:
                DriveView()
            case .contacts:
                ContactsView()
            case .mail:
                MailView()
            case .messages:
                // Mac-only (chat.db + Messages automation don't exist on iOS).
                #if os(macOS)
                MessagesView()
                #else
                EmptyView()
                #endif
            case .clock:
                ClockView()
            case .photos:
                PhotosView()
            case .claude:
                ClaudeView()
            }
        }
    }
}

/// Sidebar entries. `phase` documents where each lands in the build order (§9).
enum SidebarItem: String, Identifiable, CaseIterable {
    case dashboard
    case calendar
    case reminders
    case notes
    case drive
    case contacts
    case mail
    case messages
    case clock
    case photos
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .notes: return "Notes"
        case .drive: return "Drive"
        case .contacts: return "Contacts"
        case .mail: return "Mail"
        case .messages: return "Messages"
        case .clock: return "Clock"
        case .photos: return "Photos"
        case .claude: return "Claude"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .notes: return "note.text"
        case .drive: return "externaldrive"
        case .contacts: return "person.2"
        case .mail: return "envelope"
        case .messages: return "message"
        case .clock: return "clock"
        case .photos: return "photo.on.rectangle"
        case .claude: return "sparkles"
        }
    }

    // iOS/iPadOS drops Messages (Mac-only; Clock takes its place); macOS keeps
    // everything. Drive ships on both — its Finder-tag half is simply absent
    // on iOS.
    static var available: [SidebarItem] {
        #if os(iOS)
        [.dashboard, .mail, .clock, .reminders, .calendar, .notes, .drive, .photos, .contacts, .claude]
        #else
        [.dashboard, .mail, .messages, .clock, .reminders, .calendar, .notes, .drive, .photos, .contacts, .claude]
        #endif
    }
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
