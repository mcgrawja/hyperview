//
//  ContactsView.swift
//  Unifyr
//
//  Full-panel Contacts module (moved off the dashboard). Browses / searches the
//  address book via ContactsBroker. Access is still gated behind an explicit
//  Connect action (§6) — opening the panel does not prompt.
//

import SwiftUI
import SwiftData

struct ContactsView: View {
    @Environment(\.brokers) private var brokers
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HVTag.name) private var allTags: [HVTag]
    @Query private var tagLinks: [HVTagLink]
    @State private var selectedTagID: UUID?

    @State private var contacts: [ContactSnapshot] = []
    @State private var access: ModuleAccess = .needsPermission
    @State private var searchText = ""
    @State private var errorText: String?
    @State private var editing: ContactSnapshot?
    @State private var groups: [ContactGroupSnapshot] = []
    /// nil = All Contacts.
    @State private var selectedGroupID: String?
    @State private var creatingGroup = false
    @State private var creatingContact = false
    @State private var newGroupName = ""
    @Environment(\.isCompactLayout) private var isCompact
    /// iPhone: pushes the contact list after picking a group/tag.
    @State private var showingCompactList = false

    /// Title of the pushed contact list on iPhone.
    private var compactListTitle: String {
        if let selectedGroupID, let group = groups.first(where: { $0.id == selectedGroupID }) {
            return group.name
        }
        if let selectedTagID, let tag = allTags.first(where: { $0.id == selectedTagID }) {
            return tag.name
        }
        return "All Contacts"
    }

    var body: some View {
        Group {
            switch access {
            case .needsPermission:
                CenteredMessage {
                    ConnectPrompt(moduleName: "Contacts", systemImage: "person.2", accent: Theme.Palette.primary) {
                        await connect()
                    }
                }
            case .blocked:
                CenteredMessage { BlockedPrompt(moduleName: "Contacts") }
            case .ready:
                if isCompact {
                    // iPhone: the groups/tags pane becomes a drill-down root.
                    NavigationStack {
                        groupsPane
                            .navigationTitle("Groups")
                            .navigationDestination(isPresented: $showingCompactList) {
                                list
                                    .navigationTitle(compactListTitle)
                                    .inlineNavigationTitle()
                            }
                    }
                } else {
                    PlatformHSplit {
                        groupsPane
                            .frame(minWidth: 160, idealWidth: 190, maxWidth: 260)
                        list
                            .frame(minWidth: 360)
                    }
                }
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Contacts")
        .task { await start() }
        .sheet(item: $editing) { contact in
            ContactEditorView(contact: contact) {
                Task { await load() }
            }
        }
        .sheet(isPresented: $creatingContact) {
            // nil contact = the editor runs in New Contact mode.
            ContactEditorView {
                Task { await load() }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    creatingContact = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .help("New Contact")
            }
        }
        .alert("New Group", isPresented: $creatingGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task {
                    _ = try? await brokers.contacts.createGroup(name: name)
                    await loadGroups()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Groups pane

    private var groupsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("GROUPS")
                    .font(Theme.Font.cardCaption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button {
                    newGroupName = ""
                    creatingGroup = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .help("New Group")
            }
            .padding(Theme.Spacing.md)
            List {
                groupRow(nil, label: "All Contacts", systemImage: "person.2")
                ForEach(groups) { group in
                    groupRow(group.id, label: group.name, systemImage: "folder")
                        .contextMenu {
                            Button("Delete Group", role: .destructive) {
                                Task {
                                    try? await brokers.contacts.deleteGroup(id: group.id)
                                    if selectedGroupID == group.id { selectedGroupID = nil }
                                    await loadGroups()
                                    await load()
                                }
                            }
                        }
                }
                if !allTags.isEmpty {
                    Section("Tags") {
                        ForEach(allTags) { tag in
                            Button {
                                selectedTagID = selectedTagID == tag.id ? nil : tag.id
                                if isCompact, selectedTagID != nil { showingCompactList = true }
                            } label: {
                                HStack(spacing: Theme.Spacing.sm) {
                                    Circle()
                                        .fill(Color(hexString: tag.colorHex) ?? Theme.Palette.primary)
                                        .frame(width: 9, height: 9)
                                    Text(tag.name).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                selectedTagID == tag.id ? Theme.Palette.primary.softFill(0.12) : Color.clear
                            )
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Theme.Palette.surface)
    }

    private func groupRow(_ groupID: String?, label: String, systemImage: String) -> some View {
        Button {
            selectedGroupID = groupID
            selectedTagID = nil
            if isCompact { showingCompactList = true }
            Task { await load() }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.Palette.primary)
                Text(label).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedGroupID == groupID ? Theme.Palette.primary.opacity(0.12) : Color.clear
        )
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let errorText {
                    EmptyStateLine(text: errorText)
                        .padding(Theme.Spacing.lg)
                } else if visibleContacts.isEmpty {
                    EmptyStateLine(text: searchText.isEmpty ? "No contacts found." : "No matches for \u{201C}\(searchText)\u{201D}.")
                        .padding(Theme.Spacing.lg)
                } else {
                    ForEach(visibleContacts) { contact in
                        Button {
                            editing = contact
                        } label: {
                            ContactRow(contact: contact)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            TagMenu(kind: TagKind.contact, key: contact.tagKey)
                            if !groups.isEmpty {
                                Menu("Add to Group") {
                                    ForEach(groups) { group in
                                        Button(group.name) {
                                            Task {
                                                try? await brokers.contacts.setMembership(
                                                    contactID: contact.id, groupID: group.id, isMember: true
                                                )
                                                await load()
                                            }
                                        }
                                    }
                                }
                            }
                            if let selectedGroupID,
                               let group = groups.first(where: { $0.id == selectedGroupID }) {
                                Button("Remove from “\(group.name)”") {
                                    Task {
                                        try? await brokers.contacts.setMembership(
                                            contactID: contact.id, groupID: selectedGroupID, isMember: false
                                        )
                                        await load()
                                    }
                                }
                            }
                        }
                        Divider().overlay(Theme.Palette.separator)
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search people")
        .onChange(of: searchText) { _, _ in Task { await load() } }
        // Pull to refresh (iOS); a no-op gesture on macOS.
        .refreshable {
            await load()
            await loadGroups()
        }
    }

    private func start() async {
        access = ModuleAccess(brokers.contacts.authorization)
        guard access == .ready else { return }
        await migrateContactTagKeysIfNeeded()
        await loadGroups()
        await load()
        await observe()
    }

    private func connect() async {
        do {
            try await brokers.contacts.requestAccess()
            access = .ready
            await loadGroups()
            await load()
            await observe()
        } catch {
            access = ModuleAccess(brokers.contacts.authorization)
        }
    }

    /// The fetched contacts, narrowed by the selected universal tag.
    private var visibleContacts: [ContactSnapshot] {
        guard let selectedTagID else { return contacts }
        let keys = Set(
            tagLinks
                .filter { $0.tagID == selectedTagID && $0.itemKind == TagKind.contact }
                .map(\.itemKey)
        )
        return contacts.filter { keys.contains($0.tagKey) }
    }

    /// One-time: contact tag links used to key on CNContact.identifier, which
    /// doesn't match across devices — remap them to the identity-based key.
    private func migrateContactTagKeysIfNeeded() async {
        let flag = "tags.contactKeysMigrated"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let contactLinks = tagLinks.filter { $0.itemKind == TagKind.contact }
        guard !contactLinks.isEmpty else {
            UserDefaults.standard.set(true, forKey: flag)
            return
        }
        guard let all = try? await brokers.contacts.fetch(BrokerQuery(limit: 5000)) else { return }
        let keyByIdentifier = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.tagKey) })
        for link in contactLinks {
            if let newKey = keyByIdentifier[link.itemKey] {
                link.itemKey = newKey
            }
        }
        try? modelContext.save()
        UserDefaults.standard.set(true, forKey: flag)
        NotificationCenter.default.post(name: .unifyrTagsChanged, object: nil)
    }

    private func loadGroups() async {
        groups = (try? await brokers.contacts.groups()) ?? []
    }

    private func load() async {
        do {
            if let selectedGroupID {
                var members = try await brokers.contacts.fetch(inGroup: selectedGroupID)
                let query = searchText.trimmingCharacters(in: .whitespaces)
                if !query.isEmpty {
                    members = members.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
                }
                contacts = members
            } else {
                let query = BrokerQuery(searchText: searchText.isEmpty ? nil : searchText, limit: 200)
                contacts = try await brokers.contacts.fetch(query)
            }
            errorText = nil
        } catch {
            errorText = "Couldn't load your contacts."
        }
    }

    private func observe() async {
        for await _ in brokers.contacts.changes() {
            await loadGroups()
            await load()
        }
    }
}

private struct CenteredMessage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack { content() }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContactRow: View {
    let contact: ContactSnapshot

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Avatar(contact: contact)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(contact.displayName)
                    .font(Theme.Font.cardBody)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var subtitle: String? {
        contact.emailAddresses.first
            ?? contact.phoneNumbers.first
            ?? contact.organizationName
    }
}

/// Thin wrapper over the shared `ContactAvatar` (Contacts/ContactPhotos.swift),
/// which Mail and Messages draw with too.
private struct Avatar: View {
    let contact: ContactSnapshot

    var body: some View {
        ContactAvatar(
            data: contact.thumbnail,
            name: [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        )
    }
}
