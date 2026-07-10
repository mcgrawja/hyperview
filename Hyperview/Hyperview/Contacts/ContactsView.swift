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
                list
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
        await load()
        await observe()
    }

    private func connect() async {
        do {
            try await brokers.contacts.requestAccess()
            access = .ready
            await load()
            await observe()
        } catch {
            access = ModuleAccess(brokers.contacts.authorization)
        }
    }

    private func load() async {
        do {
            let query = BrokerQuery(searchText: searchText.isEmpty ? nil : searchText, limit: 200)
            contacts = try await brokers.contacts.fetch(query)
            errorText = nil
        } catch {
            errorText = "Couldn't load your contacts."
        }
    }

    private func observe() async {
        for await _ in brokers.contacts.changes() {
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
