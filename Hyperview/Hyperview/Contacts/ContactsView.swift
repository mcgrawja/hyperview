//
//  ContactsView.swift
//  Hyperview
//
//  Full-panel Contacts module (moved off the dashboard). Browses / searches the
//  address book via ContactsBroker. Access is still gated behind an explicit
//  Connect action (§6) — opening the panel does not prompt.
//

import SwiftUI

struct ContactsView: View {
    @Environment(\.brokers) private var brokers

    @State private var contacts: [ContactSnapshot] = []
    @State private var access: ModuleAccess = .needsPermission
    @State private var searchText = ""
    @State private var errorText: String?
    @State private var editing: ContactSnapshot?
    @State private var groups: [ContactGroupSnapshot] = []
    /// nil = All Contacts.
    @State private var selectedGroupID: String?
    @State private var creatingGroup = false
    @State private var newGroupName = ""

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
                HSplitView {
                    groupsPane
                        .frame(minWidth: 160, idealWidth: 190, maxWidth: 260)
                    list
                        .frame(minWidth: 360)
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
            }
            .listStyle(.sidebar)
        }
        .background(Theme.Palette.surface)
    }

    private func groupRow(_ groupID: String?, label: String, systemImage: String) -> some View {
        Button {
            selectedGroupID = groupID
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
                } else if contacts.isEmpty {
                    EmptyStateLine(text: searchText.isEmpty ? "No contacts found." : "No matches for \u{201C}\(searchText)\u{201D}.")
                        .padding(Theme.Spacing.lg)
                } else {
                    ForEach(contacts) { contact in
                        Button {
                            editing = contact
                        } label: {
                            ContactRow(contact: contact)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
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
    }

    private func start() async {
        access = ModuleAccess(brokers.contacts.authorization)
        guard access == .ready else { return }
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

private struct Avatar: View {
    let contact: ContactSnapshot

    var body: some View {
        Group {
            if let data = contact.thumbnail, let image = platformImage(data) {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Theme.Palette.primary.opacity(0.15))
                    Text(initials)
                        .font(Theme.Font.cardBody.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primary)
                }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private var initials: String {
        let first = contact.givenName.first.map(String.init) ?? ""
        let last = contact.familyName.first.map(String.init) ?? ""
        let combined = first + last
        return combined.isEmpty ? "?" : combined.uppercased()
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #endif
    }
}
