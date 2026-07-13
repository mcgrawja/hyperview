//
//  MailView.swift
//  Hyperview
//
//  Phase 4 Mail module: a three-pane view (mailboxes · message list · reading
//  pane) over the local cache, driven by MailService. Supports multiple
//  IMAP/SMTP accounts, each with its own sidebar section and live connection.
//  Applies the dedicated, non-CloudKit mail container to its own subtree (D9).
//

import SwiftUI
import SwiftData

struct MailView: View {
    @Environment(\.mailContainer) private var mailContainer

    var body: some View {
        Group {
            if let mailContainer {
                MailModuleContent()
                    .modelContainer(mailContainer)
            } else {
                Text("Mail store unavailable.")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .navigationTitle("Mail")
    }
}

/// Sidebar selection: one mailbox of one account.
struct MailboxSelection: Hashable {
    let accountID: UUID
    let path: String
}

/// A cross-account smart box (unified Inbox/Sent/Trash).
enum UnifiedBox: String, CaseIterable, Hashable {
    case inbox, sent, trash

    var title: String {
        switch self {
        case .inbox: return "All Inboxes"
        case .sent: return "All Sent"
        case .trash: return "All Trash"
        }
    }

    var icon: String {
        switch self {
        case .inbox: return "tray.2"
        case .sent: return "paperplane"
        case .trash: return "trash"
        }
    }
}

/// What the mail sidebar can select: a unified box, one concrete mailbox, or a
/// tag (all cached messages carrying it, across accounts).
enum MailSidebarSelection: Hashable {
    case unified(UnifiedBox)
    case mailbox(MailboxSelection)
    case tag(UUID)
    case smart(UUID)
}

private struct MailModuleContent: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MailAccount.createdAt) private var accounts: [MailAccount]
    @Query(sort: \Mailbox.sortIndex) private var mailboxes: [Mailbox]
    @Query private var messages: [MailMessage]
    // Universal tags (main CloudKit container) — this subtree's \.modelContext
    // is the mail cache, so tags come through the app-level TagsStore.
    @Environment(\.tagsStore) private var tagsStore
    @Query(sort: \SmartMailbox.sortIndex) private var smartMailboxes: [SmartMailbox]
    @Query(sort: \BlockedSender.address) private var blockedSenders: [BlockedSender]
    @Query(sort: \MailRule.sortIndex) private var rules: [MailRule]

    /// Shared, app-level service (also used by the MCP tools) — connections
    /// survive tab switches.
    @Environment(\.mailService) private var envService
    private var service: MailService { envService ?? MailService() }
    @State private var selection: MailSidebarSelection?
    @State private var selectedMessage: MailMessage?
    @State private var searchText = ""
    @State private var composeSheet: ComposeSheet?
    @State private var addingAccount = false
    @State private var settingsAccount: MailAccount?
    @State private var smartEditor: SmartMailboxEditorTarget?
    @State private var showingRules = false
    @State private var showingBlockedSenders = false
    /// Master disclosure for the per-account sections. Collapsed by default so
    /// the sidebar leads with just the unified boxes.
    @AppStorage("mail.accountsSectionExpanded") private var accountsExpanded = false
    @Environment(\.isCompactLayout) private var isCompact
    @AppStorage("mail.unifiedSectionExpanded") private var unifiedExpanded = true
    @AppStorage("mail.smartSectionExpanded") private var smartExpanded = true
    @AppStorage("mail.tagsSectionExpanded") private var tagsExpanded = true

    var body: some View {
        if accounts.isEmpty {
            AccountSetupView()
        } else {
            mailboxLayout
        }
    }

    /// The single account a concrete-mailbox selection belongs to (nil for
    /// unified boxes — those span accounts).
    private var selectedAccount: MailAccount? {
        guard case .mailbox(let box) = selection else { return nil }
        return accounts.first { $0.id == box.accountID }
    }

    /// The (account, mailboxPath) pairs the current selection covers.
    private func selectedFolders() -> [(account: MailAccount, path: String)] {
        switch selection {
        case .unified(let box):
            return accounts.map { account in
                switch box {
                case .inbox: return (account, "INBOX")
                case .sent: return (account, service.sentPath(for: account))
                case .trash: return (account, service.trashPath(for: account))
                }
            }
        case .mailbox(let box):
            guard let account = accounts.first(where: { $0.id == box.accountID }) else { return [] }
            return [(account, box.path)]
        case .tag, .smart, nil:
            return [] // local views over the cache; nothing to sync
        }
    }

    /// Navigation-triggered syncs are quiet (no banner); only the explicit
    /// Refresh button shows progress.
    private func syncSelection(quiet: Bool = true) async {
        for (account, path) in selectedFolders() {
            await service.syncMessages(account, mailboxPath: path, quiet: quiet)
        }
    }

    private var mailboxLayout: some View {
        Group {
            if isCompact {
                compactPanes
            } else {
                regularPanes
            }
        }
        .background(Theme.Palette.background)
        // Search lives in the window toolbar (like Apple Mail) so no pane
        // spends a row on it — the message list starts at the top.
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search mail")
        .onSubmit(of: .search) {
            Task {
                for (account, path) in selectedFolders() {
                    await service.search(account, mailboxPath: path, query: searchText)
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty { Task { await syncSelection() } }
        }
        // Universal-search deep link: select the message wherever it lives.
        .onReceive(NotificationCenter.default.publisher(for: .hyperviewOpenMailMessage)) { notification in
            guard let id = notification.userInfo?["id"] as? UUID,
                  let message = messages.first(where: { $0.id == id }) else { return }
            selection = .mailbox(MailboxSelection(accountID: message.accountID, path: message.mailboxPath))
            selectedMessage = message
        }
        .task(id: accounts.map(\.id)) {
            service.context = context
            // Auto-select a mailbox only where a message list is always
            // visible. On iPhone, selection PUSHES a screen — auto-selecting
            // would drop the user straight into a mailbox with no way back to
            // the list they never saw.
            if !isCompact, selection == nil, let first = accounts.first {
                selection = accounts.count > 1
                    ? .unified(.inbox)
                    : .mailbox(MailboxSelection(accountID: first.id, path: "INBOX"))
            }
            // A lone account has no unified section — don't hide everything.
            if accounts.count == 1 {
                accountsExpanded = true
                accounts.first?.isExpanded = true
            }
            for account in accounts {
                await service.connect(account)
            }
            await syncSelection()
        }
        .toolbar {
            // A phone nav bar can't hold five buttons — on compact, everything
            // but Compose and Refresh collapses into one overflow menu.
            if isCompact {
                ToolbarItem {
                    Button { composeSheet = ComposeSheet(mode: .new) } label: { Image(systemName: "square.and.pencil") }
                }
                ToolbarItem {
                    Button {
                        Task { await syncSelection(quiet: false) }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem {
                    Menu {
                        Button("Add Account…") { addingAccount = true }
                        Divider()
                        Button("New Smart Mailbox…") { smartEditor = SmartMailboxEditorTarget(box: nil) }
                        Button("Manage Rules…") { showingRules = true }
                        Button("Blocked Senders…") { showingBlockedSenders = true }
                        Divider()
                        Button("Re-download Messages") { Task { await clearCacheAndReload() } }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            } else {
                ToolbarItem {
                    Button { composeSheet = ComposeSheet(mode: .new) } label: { Image(systemName: "square.and.pencil") }
                        .help("Compose")
                }
                ToolbarItem {
                    Button {
                        Task { await syncSelection(quiet: false) }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                }
                ToolbarItem {
                    Button {
                        Task { await clearCacheAndReload() }
                    } label: { Image(systemName: "arrow.triangle.2.circlepath.circle") }
                    .help("Clear cached messages and re-download")
                }
                ToolbarItem {
                    Menu {
                        Button("New Smart Mailbox…") { smartEditor = SmartMailboxEditorTarget(box: nil) }
                        Button("Manage Rules…") { showingRules = true }
                        Button("Blocked Senders…") { showingBlockedSenders = true }
                    } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Smart Mailboxes & Rules")
                }
                ToolbarItem {
                    Button { addingAccount = true } label: { Image(systemName: "person.crop.circle.badge.plus") }
                        .help("Add Account")
                }
            }
        }
        .sheet(item: $composeSheet) { sheet in
            ComposeView(accounts: accounts, defaultAccount: selectedAccount, service: service, mode: sheet.mode)
        }
        .sheet(isPresented: $addingAccount) {
            AccountSetupView(showsCancel: true) {
                addingAccount = false
            }
            .frame(width: 480, height: 560)
        }
        .sheet(item: $settingsAccount) { account in
            AccountSettingsView(account: account)
        }
        .sheet(item: $smartEditor) { target in
            SmartMailboxEditorView(target: target, accounts: accounts)
        }
        .sheet(isPresented: $showingRules) {
            RulesManagerView(accounts: accounts)
        }
        .sheet(isPresented: $showingBlockedSenders) {
            BlockedSendersView()
        }
    }

    // MARK: Panes

    /// Mac / iPad: all three panes side by side. Default proportions —
    /// mailboxes ~5%, message list ~20%, reading pane the rest.
    private var regularPanes: some View {
        GeometryReader { geometry in
            PlatformHSplit {
                mailboxPane
                    .frame(minWidth: 105, idealWidth: geometry.size.width * 0.049, maxWidth: 300)
                messageListPane
                    .frame(minWidth: 220, idealWidth: geometry.size.width * 0.20, maxWidth: 520)
                detailPane
                    .frame(minWidth: 360, idealWidth: geometry.size.width * 0.735, maxWidth: .infinity)
            }
        }
    }

    /// iPhone: one pane at a time — mailboxes → messages → the message.
    private var compactPanes: some View {
        NavigationStack {
            mailboxPane
                .navigationTitle("Mailboxes")
                .navigationDestination(item: $selection) { _ in
                    messageListPane
                        .navigationTitle(compactListTitle)
                        .inlineNavigationTitle()
                        .navigationDestination(item: $selectedMessage) { _ in
                            detailPane
                                .inlineNavigationTitle()
                        }
                }
        }
    }

    /// Title for the message-list screen on iPhone.
    private var compactListTitle: String {
        switch selection {
        case .unified(let box): return box.title
        case .mailbox(let box):
            return mailboxes.first { $0.accountID == box.accountID && $0.path == box.path }?.displayName ?? box.path
        case .smart(let id): return smartMailboxes.first { $0.id == id }?.name ?? "Smart Mailbox"
        case .tag(let id): return tagsStore?.tags.first { $0.id == id }?.name ?? "Tag"
        case nil: return "Mail"
        }
    }

    private var mailboxPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner
            List(selection: $selection) {
                if accounts.count > 1 {
                    Section(isExpanded: $unifiedExpanded) {
                        ForEach(UnifiedBox.allCases, id: \.self) { box in
                            HStack {
                                Image(systemName: box.icon)
                                    .foregroundStyle(Theme.Palette.primary)
                                Text(box.title)
                                Spacer()
                                if box == .inbox {
                                    let unread = accounts.reduce(0) { total, account in
                                        total + (accountMailboxes(account).first { $0.path.uppercased() == "INBOX" }?.unreadCount ?? 0)
                                    }
                                    if unread > 0 {
                                        CountBadge(count: unread, accent: Theme.Palette.primary)
                                    }
                                }
                            }
                            .tag(MailSidebarSelection.unified(box))
                        }
                    } header: {
                        Text("All Accounts")
                    }
                }
                if !smartMailboxes.isEmpty {
                    Section(isExpanded: $smartExpanded) {
                        ForEach(smartMailboxes) { box in
                            HStack {
                                Image(systemName: "gearshape.2")
                                    .foregroundStyle(Color(hexString: box.colorHex) ?? Theme.Palette.primary)
                                Text(box.name).lineLimit(1)
                            }
                            .tag(MailSidebarSelection.smart(box.id))
                            .contextMenu {
                                Button("Edit Smart Mailbox…") { smartEditor = SmartMailboxEditorTarget(box: box) }
                                Divider()
                                Button("Delete Smart Mailbox", role: .destructive) { deleteSmartMailbox(box) }
                            }
                        }
                    } header: {
                        Text("Smart Mailboxes")
                    }
                }
                if let tagsStore, !tagsStore.tags.isEmpty {
                    Section(isExpanded: $tagsExpanded) {
                        ForEach(tagsStore.tags) { tag in
                            HStack {
                                Circle()
                                    .fill(Color(hexString: tag.colorHex) ?? Theme.Palette.primary)
                                    .frame(width: 9, height: 9)
                                Text(tag.name).lineLimit(1)
                                Spacer()
                                let count = tagsStore.count(tag.id, kind: TagKind.mail)
                                if count > 0 {
                                    CountBadge(count: count, accent: Color(hexString: tag.colorHex) ?? Theme.Palette.primary)
                                }
                            }
                            .tag(MailSidebarSelection.tag(tag.id))
                            .contextMenu {
                                Button("Edit Tags…") {
                                    NotificationCenter.default.post(name: .hyperviewShowTagManager, object: nil)
                                }
                            }
                        }
                    } header: {
                        Text("Tags")
                    }
                }
                Section(isExpanded: $accountsExpanded) {
                    ForEach(accounts) { account in
                        @Bindable var account = account
                        DisclosureGroup(isExpanded: $account.isExpanded) {
                            ForEach(accountMailboxes(account)) { box in
                                HStack {
                                    Image(systemName: icon(for: box.path))
                                        .foregroundStyle(badgeColor(for: account))
                                    Text(box.displayName).lineLimit(1)
                                    Spacer()
                                    if box.unreadCount > 0 {
                                        CountBadge(count: box.unreadCount, accent: badgeColor(for: account))
                                    }
                                }
                                .tag(MailSidebarSelection.mailbox(MailboxSelection(accountID: account.id, path: box.path)))
                            }
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Circle()
                                    .fill(badgeColor(for: account))
                                    .frame(width: 9, height: 9)
                                Text(displayName(for: account))
                                    .lineLimit(1)
                                    .help(account.emailAddress)
                            }
                            .contextMenu {
                                Button("Account Settings…") { settingsAccount = account }
                                Divider()
                                Button("Remove Account…", role: .destructive) {
                                    Task { await removeAccount(account) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Accounts")
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, _ in
                selectedMessage = nil
                Task { await syncSelection() }
            }
        }
        .background(Theme.Palette.surface)
    }

    private var messageListPane: some View {
        VStack(spacing: 0) {
            List(selection: $selectedMessage) {
                ForEach(visibleMessages) { message in
                    let badge = originBadge(for: message)
                    MessageRow(
                        message: message,
                        origin: badge?.label,
                        originColor: badge?.color ?? Theme.Palette.primary,
                        tagColors: tagsFor(message).map { Color(hexString: $0.colorHex) ?? Theme.Palette.primary }
                    )
                    .tag(message)
                    .contextMenu { messageContextMenu(message) }
                }
            }
            .listStyle(.inset)
            // Delete key — macOS only (iOS uses swipe-to-delete, Phase 2).
            #if os(macOS)
            .onDeleteCommand {
                guard let message = selectedMessage else { return }
                Task { await deleteMessage(message) }
            }
            #endif
        }
        .background(Theme.Palette.surface)
    }

    private var detailPane: some View {
        // ZStack keeps the pane's view identity STABLE across the placeholder
        // ↔ message swap — otherwise HSplitView re-applies the ideal widths
        // and the reading pane visibly snaps back on every selection.
        ZStack {
            detailPaneContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPaneContent: some View {
        // Account resolved from the MESSAGE (selection may be a unified box).
        if let selectedMessage,
           let account = accounts.first(where: { $0.id == selectedMessage.accountID }) {
            MessageDetailView(
                message: selectedMessage,
                account: account,
                service: service,
                onDelete: { Task { await deleteMessage(selectedMessage) } },
                onCompose: { mode in composeSheet = ComposeSheet(mode: mode) }
            )
            .id(selectedMessage.id)
        } else {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 42))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Select a message")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        // A misconfigured RULE (e.g. moving mail into a mailbox the server
        // won't accept) is a config problem, not a broken account — it gets
        // its own actionable banner naming the rule.
        ForEach(rules.filter { service.ruleErrors[$0.id] != nil }) { rule in
            ruleBanner(rule)
        }
        // Persistent per-account failures — these survive other accounts'
        // successes (a login error must not be masked by a healthy sync).
        ForEach(accounts.filter { service.accountErrors[$0.id] != nil }) { account in
            banner(
                service.accountErrors[account.id] ?? "",
                systemImage: "exclamationmark.triangle",
                tint: Theme.Palette.danger
            )
        }
        switch service.status {
        case .connecting:
            banner("Connecting…", systemImage: "antenna.radiowaves.left.and.right", tint: Theme.Palette.primary)
        case .syncing:
            banner("Syncing…", systemImage: "arrow.triangle.2.circlepath", tint: Theme.Palette.primary)
        case .error(let message):
            if !service.accountErrors.values.contains(message) {
                banner(message, systemImage: "exclamationmark.triangle", tint: Theme.Palette.danger)
            }
        case .idle, .connected:
            EmptyView()
        }
    }

    /// Names the broken rule and offers the two fixes inline: disable it, or
    /// open Manage Rules to repoint it.
    private func ruleBanner(_ rule: MailRule) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
            Text(service.ruleErrors[rule.id] ?? "")
                .font(Theme.Font.cardCaption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Disable Rule") {
                rule.isEnabled = false
                try? context.save()
                service.ruleErrors[rule.id] = nil
            }
            Button("Edit Rules…") {
                showingRules = true
                service.ruleErrors[rule.id] = nil
            }
            Button {
                service.ruleErrors[rule.id] = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .foregroundStyle(Theme.Palette.warning)
        .padding(Theme.Spacing.sm)
        .background(Theme.Palette.warning.opacity(0.12))
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
            Text(text).font(Theme.Font.cardCaption).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(Theme.Spacing.sm)
        .background(tint.opacity(0.1))
    }

    // MARK: Message actions

    @ViewBuilder
    private func messageContextMenu(_ message: MailMessage) -> some View {
        if let account = accounts.first(where: { $0.id == message.accountID }) {
            Button(message.isSeen ? "Mark as Unread" : "Mark as Read") {
                Task { await service.setSeen(message, account: account, seen: !message.isSeen) }
            }
            Button(message.isFlagged ? "Unflag" : "Flag") {
                Task { await service.setFlagged(message, account: account, flagged: !message.isFlagged) }
            }
            if blockedSenders.contains(where: { $0.address == message.fromAddress.lowercased() }) {
                Button("Unblock Sender") {
                    for blocked in blockedSenders where blocked.address == message.fromAddress.lowercased() {
                        context.delete(blocked)
                    }
                    try? context.save()
                }
            } else {
                Button("Block Sender") {
                    context.insert(BlockedSender(address: message.fromAddress))
                    try? context.save()
                    Task { await deleteMessage(message) }
                }
            }
            Menu("Move To") {
                ForEach(accountMailboxes(account).filter { $0.path != message.mailboxPath }) { box in
                    Button(box.displayName) {
                        Task { await moveMessage(message, account: account, to: box.path) }
                    }
                }
            }
            if let header = message.messageID, let tagsStore {
                Menu("Tags") {
                    ForEach(tagsStore.tags) { tag in
                        let isOn = tagsStore.isTagged(tag.id, kind: TagKind.mail, key: header)
                        Button {
                            tagsStore.toggle(tag.id, kind: TagKind.mail, key: header)
                        } label: {
                            if isOn {
                                Label(tag.name, systemImage: "checkmark")
                            } else {
                                Text(tag.name)
                            }
                        }
                    }
                    if !tagsStore.tags.isEmpty { Divider() }
                    Button("Edit Tags…") {
                        NotificationCenter.default.post(name: .hyperviewShowTagManager, object: nil)
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await deleteMessage(message) }
            }
        }
    }

    // MARK: Tags

    private func deleteSmartMailbox(_ box: SmartMailbox) {
        if case .smart(let id) = selection, id == box.id { selection = nil }
        context.delete(box)
        try? context.save()
    }

    private func tagsFor(_ message: MailMessage) -> [TagInfo] {
        guard let header = message.messageID, let tagsStore else { return [] }
        return tagsStore.tags(kind: TagKind.mail, key: header)
    }

    private func deleteMessage(_ message: MailMessage) async {
        guard let account = accounts.first(where: { $0.id == message.accountID }) else { return }
        if selectedMessage?.id == message.id { selectedMessage = nil }
        await service.delete(message, account: account)
    }

    private func moveMessage(_ message: MailMessage, account: MailAccount, to path: String) async {
        if selectedMessage?.id == message.id { selectedMessage = nil }
        await service.move(message, account: account, to: path)
    }

    // MARK: Actions

    /// Purge the local message cache for every account the current selection
    /// covers, then re-download. Mail is a server-authoritative cache (D9), so
    /// this is always safe — nothing local-only is lost.
    private func clearCacheAndReload() async {
        selectedMessage = nil
        let accountIDs = Set(selectedFolders().map(\.account.id))
        for message in messages where accountIDs.contains(message.accountID) {
            context.delete(message)
        }
        try? context.save()
        await syncSelection()
    }

    private func removeAccount(_ account: MailAccount) async {
        if case .mailbox(let box) = selection, box.accountID == account.id {
            selection = nil
        }
        selectedMessage = nil
        await service.removeAccount(account)
    }

    // MARK: Helpers

    private func accountMailboxes(_ account: MailAccount) -> [Mailbox] {
        mailboxes.filter { $0.accountID == account.id }
    }

    private var visibleMessages: [MailMessage] {
        let base = unsearchedMessages
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        // Live local narrowing while typing; ⏎ still runs the server search
        // (which pulls matches into the cache and so into `base`).
        return base.filter {
            $0.subject.localizedCaseInsensitiveContains(query)
                || $0.fromAddress.localizedCaseInsensitiveContains(query)
                || $0.fromName.localizedCaseInsensitiveContains(query)
        }
    }

    private var unsearchedMessages: [MailMessage] {
        if case .smart(let boxID) = selection {
            guard let box = smartMailboxes.first(where: { $0.id == boxID }) else { return [] }
            let condition = box.condition
            // Dedupe (a message can be cached under several folders).
            var seen = Set<String>()
            return messages
                .filter { message in
                    guard condition.matches(message) else { return false }
                    let key = message.messageID ?? message.id.uuidString
                    return seen.insert(key).inserted
                }
                .sorted { $0.date > $1.date }
        }
        if case .tag(let tagID) = selection {
            let headers = tagsStore?.keys(with: tagID, kind: TagKind.mail) ?? []
            // A message can be cached in several folders (e.g. inbox + All Mail);
            // dedupe by Message-ID for the tag view.
            var seen = Set<String>()
            return messages
                .filter { message in
                    guard let header = message.messageID, headers.contains(header) else { return false }
                    return seen.insert(header).inserted
                }
                .sorted { $0.date > $1.date }
        }
        let folders = selectedFolders()
        guard !folders.isEmpty else { return [] }
        let keys = Set(folders.map { "\($0.account.id.uuidString)|\($0.path)" })
        return messages
            .filter { keys.contains("\($0.accountID.uuidString)|\($0.mailboxPath)") }
            .sorted { $0.date > $1.date }
    }

    /// In unified boxes, tag each row with which account it came from.
    private var isUnifiedSelection: Bool {
        if case .unified = selection { return true }
        return false
    }

    /// The account's badge tint (customizable in Account Settings).
    private func badgeColor(for account: MailAccount) -> Color {
        Color(hexString: account.badgeColorHex) ?? Theme.Palette.primary
    }

    /// The account's badge word / sidebar name (customizable; domain fallback).
    private func displayName(for account: MailAccount) -> String {
        account.badgeLabel.isEmpty
            ? (account.emailAddress.split(separator: "@").last.map(String.init) ?? account.emailAddress)
            : account.badgeLabel
    }

    private func originBadge(for message: MailMessage) -> (label: String, color: Color)? {
        guard isUnifiedSelection,
              let account = accounts.first(where: { $0.id == message.accountID }) else { return nil }
        return (displayName(for: account), badgeColor(for: account))
    }

    private func icon(for path: String) -> String {
        switch path.uppercased() {
        case "INBOX": return "tray"
        case let p where p.contains("SENT"): return "paperplane"
        case let p where p.contains("DRAFT"): return "doc"
        case let p where p.contains("TRASH") || p.contains("DELETED"): return "trash"
        case let p where p.contains("SPAM") || p.contains("JUNK"): return "xmark.bin"
        case let p where p.contains("ARCHIVE"): return "archivebox"
        default: return "folder"
        }
    }
}

// MARK: - Rows / detail

private struct MessageRow: View {
    let message: MailMessage
    /// Set in unified boxes: which account this message belongs to.
    var origin: String? = nil
    var originColor: Color = Theme.Palette.primary
    /// Colors of the message's tags, shown as small dots.
    var tagColors: [Color] = []

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Circle()
                .fill(message.isSeen ? Color.clear : Theme.Palette.primary)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack {
                    Text(message.fromName.isEmpty ? message.fromAddress : message.fromName)
                        .font(Theme.Font.cardBody.weight(message.isSeen ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.warning)
                    }
                    Text(message.date.formatted(date: .abbreviated, time: .omitted))
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                HStack(spacing: Theme.Spacing.xs) {
                    if !tagColors.isEmpty {
                        HStack(spacing: 2) {
                            ForEach(Array(tagColors.enumerated()), id: \.offset) { _, color in
                                Circle().fill(color).frame(width: 7, height: 7)
                            }
                        }
                    }
                    Text(message.subject)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(message.isSeen ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                        .lineLimit(1)
                    if let origin {
                        Spacer(minLength: 0)
                        Text(origin)
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(originColor)
                            .padding(.horizontal, Theme.Spacing.xs)
                            .background(originColor.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

private struct MessageDetailView: View {
    let message: MailMessage
    let account: MailAccount
    let service: MailService
    var onDelete: () -> Void
    var onCompose: (ComposeMode) -> Void

    @Query private var attachments: [MailAttachment]
    @State private var eventSheet: EventFromEmailSheet?
    @State private var feedback: String?

    init(
        message: MailMessage,
        account: MailAccount,
        service: MailService,
        onDelete: @escaping () -> Void = {},
        onCompose: @escaping (ComposeMode) -> Void = { _ in }
    ) {
        self.message = message
        self.account = account
        self.service = service
        self.onDelete = onDelete
        self.onCompose = onCompose
        let messageID = message.id
        _attachments = Query(filter: #Predicate<MailAttachment> { $0.messageID == messageID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(message.subject)
                    .font(Theme.Font.dashboardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                HStack(spacing: Theme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.fromName.isEmpty ? message.fromAddress : message.fromName)
                            .font(Theme.Font.cardBody.weight(.semibold))
                        if !message.fromName.isEmpty {
                            Text(message.fromAddress).font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    Spacer()
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Button { onCompose(.reply(message, all: false)) } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reply")
                    Button { onCompose(.reply(message, all: true)) } label: {
                        Image(systemName: "arrowshape.turn.up.left.2")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reply All")
                    Button { onCompose(.forward(message)) } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Forward")
                    Button {
                        Task { await service.setFlagged(message, account: account, flagged: !message.isFlagged) }
                    } label: {
                        Image(systemName: message.isFlagged ? "flag.fill" : "flag")
                            .foregroundStyle(message.isFlagged ? Theme.Palette.warning : Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(message.isFlagged ? "Unflag" : "Flag")
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Move to Trash")
                    MailActionsMenu(message: message, onFeedback: showFeedback, eventSheet: $eventSheet, accountEmail: account.emailAddress)
                }
            }
            .padding(Theme.Spacing.xl)

            if let feedback {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "checkmark.circle")
                    Text(feedback).font(Theme.Font.cardCaption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.Palette.success)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.sm)
                .transition(.opacity)
            }

            if !visibleAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(visibleAttachments) { attachment in
                            AttachmentChip(attachment: attachment)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.sm)
                }
            }
            Divider().overlay(Theme.Palette.separator)

            if message.hasFetchedBody {
                MailBodyWebView(html: inlinedHTML, plainText: message.bodyText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Palette.background)
        .sheet(item: $eventSheet) { sheet in
            EventFromEmailView(message: sheet.message, onFeedback: showFeedback)
        }
        .task {
            if !message.hasFetchedBody || cachedBodyLooksUnparsed {
                await service.loadBody(message, account: account)
            }
        }
    }

    private func showFeedback(_ text: String) {
        withAnimation { feedback = text }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { feedback = nil }
        }
    }

    /// Bodies cached by an earlier, buggier MIME parser can contain raw
    /// multipart source (boundary lines) in `bodyText` with no HTML extracted.
    /// Refetch those so a parser fix heals the cache on open.
    private var cachedBodyLooksUnparsed: Bool {
        guard message.bodyHTML == nil else { return false }
        guard let text = message.bodyText else { return true }
        return text.contains("Content-Type:") || text.hasPrefix("--")
    }

    /// Inline (cid:) parts render inside the HTML; only genuinely file-like
    /// attachments get a chip.
    private var visibleAttachments: [MailAttachment] {
        attachments.filter { attachment in
            guard let cid = attachment.contentID, !cid.isEmpty else { return true }
            // Referenced by the HTML → it's an embedded image, not a file.
            return !(message.bodyHTML?.contains("cid:\(cid)") ?? false)
        }
    }

    /// HTML with `cid:` image references replaced by inline data URIs — this is
    /// what makes embedded images show up.
    private var inlinedHTML: String? {
        guard var html = message.bodyHTML else { return nil }
        for attachment in attachments {
            guard let cid = attachment.contentID, !cid.isEmpty else { continue }
            let dataURI = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            html = html.replacingOccurrences(of: "cid:\(cid)", with: dataURI)
        }
        return html
    }
}

/// A clickable attachment pill: click to save.
private struct AttachmentChip: View {
    let attachment: MailAttachment

    var body: some View {
        Button(action: save) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: iconName)
                    .foregroundStyle(Theme.Palette.primary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.filename)
                        .font(Theme.Font.cardCaption.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text(sizeLabel)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Image(systemName: "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .help("Save \(attachment.filename)")
    }

    private var iconName: String {
        if attachment.mimeType.hasPrefix("image/") { return "photo" }
        if attachment.mimeType.contains("pdf") { return "doc.richtext" }
        if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        return "doc"
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
    }

    private func save() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? attachment.data.write(to: url)
        }
        #endif
    }
}

// MARK: - Small helpers

/// Very small HTML-to-text fallback for messages that are HTML-only.
enum MailText {
    static func strip(_ html: String) -> String {
        var text = html
        for (tag, replacement) in [("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"), ("</p>", "\n\n"), ("</div>", "\n")] {
            text = text.replacingOccurrences(of: tag, with: replacement, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
