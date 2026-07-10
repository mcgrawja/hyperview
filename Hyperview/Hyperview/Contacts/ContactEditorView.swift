//
//  ContactEditorView.swift
//  Hyperview
//
//  Edit (or delete) a contact: name, organization, emails, phones. Saves via
//  ContactsBroker.updateContact — the same verb the contacts_update MCP tool
//  uses.
//

import SwiftUI

struct ContactEditorView: View {
    let contact: ContactSnapshot
    var onSaved: () -> Void = {}

    @Environment(\.brokers) private var brokers
    @Environment(\.dismiss) private var dismiss

    @State private var givenName: String
    @State private var familyName: String
    @State private var organization: String
    @State private var emails: [String]
    @State private var phones: [String]
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var errorText: String?

    init(contact: ContactSnapshot, onSaved: @escaping () -> Void = {}) {
        self.contact = contact
        self.onSaved = onSaved
        _givenName = State(initialValue: contact.givenName)
        _familyName = State(initialValue: contact.familyName)
        _organization = State(initialValue: contact.organizationName ?? "")
        _emails = State(initialValue: contact.emailAddresses.isEmpty ? [""] : contact.emailAddresses)
        _phones = State(initialValue: contact.phoneNumbers.isEmpty ? [""] : contact.phoneNumbers)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Edit Contact").font(Theme.Font.cardTitle)

                HStack(spacing: Theme.Spacing.sm) {
                    TextField("First name", text: $givenName).textFieldStyle(.roundedBorder)
                    TextField("Last name", text: $familyName).textFieldStyle(.roundedBorder)
                }
                TextField("Organization", text: $organization).textFieldStyle(.roundedBorder)

                fieldList(title: "EMAILS", items: $emails, prompt: "email@example.com")
                fieldList(title: "PHONES", items: $phones, prompt: "(555) 555-5555")

                if let errorText {
                    Text(errorText)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.danger)
                }

                HStack {
                    Button("Delete Contact…", role: .destructive) { confirmingDelete = true }
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
                    .disabled(saving)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: 420, height: 440)
        .background(Theme.Palette.background)
        .confirmationDialog("Delete \(contact.displayName)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the contact from your address book everywhere.")
        }
    }

    private func fieldList(title: String, items: Binding<[String]>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Font.cardCaption.weight(.semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
            ForEach(items.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: Theme.Spacing.xs) {
                    TextField(prompt, text: items[index]).textFieldStyle(.roundedBorder)
                    Button {
                        items.wrappedValue.remove(at: index)
                        if items.wrappedValue.isEmpty { items.wrappedValue = [""] }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                items.wrappedValue.append("")
            } label: {
                Label("Add", systemImage: "plus.circle")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.primary)
            }
            .buttonStyle(.plain)
        }
    }

    private func save() async {
        saving = true
        do {
            _ = try await brokers.contacts.updateContact(
                id: contact.id,
                givenName: givenName,
                familyName: familyName,
                organization: organization,
                emails: emails.map { $0.trimmingCharacters(in: .whitespaces) },
                phones: phones.map { $0.trimmingCharacters(in: .whitespaces) }
            )
            saving = false
            onSaved()
            dismiss()
        } catch {
            saving = false
            errorText = "Couldn't save — check Contacts access."
        }
    }

    private func delete() async {
        do {
            try await brokers.contacts.deleteContact(id: contact.id)
            onSaved()
            dismiss()
        } catch {
            errorText = "Couldn't delete the contact."
        }
    }
}
