//
//  ContactEditorView.swift
//  Unifyr
//
//  Edit (or delete) a contact with the full Apple-Contacts card: names
//  (prefix/middle/suffix/nickname/phonetics), work, labeled emails/phones/
//  URLs, postal addresses, birthday + dates, related names, social profiles,
//  and instant messages. Saves via ContactsBroker.saveContact. Contact notes
//  are excluded — Apple gates that field behind a restricted entitlement.
//

import SwiftUI

struct ContactEditorView: View {
    let contact: ContactSnapshot
    var onSaved: () -> Void = {}

    @Environment(\.brokers) private var brokers
    @Environment(\.dismiss) private var dismiss

    @State private var edit: ContactEditData
    @State private var hasBirthday: Bool
    @State private var birthday: Date
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var errorText: String?

    init(contact: ContactSnapshot, onSaved: @escaping () -> Void = {}) {
        self.contact = contact
        self.onSaved = onSaved
        var data = ContactEditData()
        data.namePrefix = contact.namePrefix
        data.givenName = contact.givenName
        data.middleName = contact.middleName
        data.familyName = contact.familyName
        data.nameSuffix = contact.nameSuffix
        data.nickname = contact.nickname
        data.phoneticGivenName = contact.phoneticGivenName
        data.phoneticFamilyName = contact.phoneticFamilyName
        data.organizationName = contact.organizationName ?? ""
        data.departmentName = contact.departmentName
        data.jobTitle = contact.jobTitle
        data.birthday = contact.birthday
        data.emails = contact.emails.isEmpty ? [LabeledValueSnapshot(label: "home", value: "")] : contact.emails
        data.phones = contact.phones.isEmpty ? [LabeledValueSnapshot(label: "mobile", value: "")] : contact.phones
        data.urls = contact.urls
        data.postalAddresses = contact.postalAddresses
        data.relations = contact.relations
        data.socialProfiles = contact.socialProfiles
        data.instantMessages = contact.instantMessages
        data.dates = contact.dates
        _edit = State(initialValue: data)
        _hasBirthday = State(initialValue: contact.birthday != nil)
        _birthday = State(initialValue: contact.birthday ?? Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Contact").font(Theme.Font.cardTitle)
                Spacer()
            }
            .padding(Theme.Spacing.lg)

            Divider().overlay(Theme.Palette.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    nameSection
                    workSection
                    labeledList(title: "PHONES", items: $edit.phones, valuePrompt: "(555) 555-5555", defaultLabel: "mobile")
                    labeledList(title: "EMAILS", items: $edit.emails, valuePrompt: "email@example.com", defaultLabel: "home")
                    labeledList(title: "URLS", items: $edit.urls, valuePrompt: "https://example.com", defaultLabel: "homepage")
                    addressSection
                    birthdaySection
                    datesSection
                    labeledList(title: "RELATED NAMES", items: $edit.relations, valuePrompt: "Name", defaultLabel: "spouse", labelPrompt: "relation")
                    labeledList(title: "SOCIAL PROFILES", items: $edit.socialProfiles, valuePrompt: "username", defaultLabel: "X", labelPrompt: "service")
                    labeledList(title: "INSTANT MESSAGES", items: $edit.instantMessages, valuePrompt: "handle", defaultLabel: "Signal", labelPrompt: "service")

                    if let errorText {
                        Text(errorText)
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
                .padding(Theme.Spacing.lg)
            }

            Divider().overlay(Theme.Palette.separator)

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
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: 520, height: 680)
        .background(Theme.Palette.background)
        .confirmationDialog("Delete \(contact.displayName)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the contact from your address book everywhere.")
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionLabel("NAME")
            HStack(spacing: Theme.Spacing.xs) {
                TextField("Prefix", text: $edit.namePrefix).textFieldStyle(.roundedBorder).frame(width: 70)
                TextField("First name", text: $edit.givenName).textFieldStyle(.roundedBorder)
                TextField("Middle", text: $edit.middleName).textFieldStyle(.roundedBorder).frame(width: 80)
                TextField("Last name", text: $edit.familyName).textFieldStyle(.roundedBorder)
                TextField("Suffix", text: $edit.nameSuffix).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            HStack(spacing: Theme.Spacing.xs) {
                TextField("Nickname", text: $edit.nickname).textFieldStyle(.roundedBorder)
                TextField("Phonetic first", text: $edit.phoneticGivenName).textFieldStyle(.roundedBorder)
                TextField("Phonetic last", text: $edit.phoneticFamilyName).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var workSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionLabel("WORK")
            TextField("Company", text: $edit.organizationName).textFieldStyle(.roundedBorder)
            HStack(spacing: Theme.Spacing.xs) {
                TextField("Job title", text: $edit.jobTitle).textFieldStyle(.roundedBorder)
                TextField("Department", text: $edit.departmentName).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionLabel("ADDRESSES")
            ForEach($edit.postalAddresses) { $address in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        TextField("label", text: $address.label)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        TextField("Street", text: $address.street).textFieldStyle(.roundedBorder)
                        removeButton { edit.postalAddresses.removeAll { $0.id == address.id } }
                    }
                    HStack(spacing: Theme.Spacing.xs) {
                        TextField("City", text: $address.city).textFieldStyle(.roundedBorder)
                        TextField("State", text: $address.state).textFieldStyle(.roundedBorder).frame(width: 70)
                        TextField("ZIP", text: $address.postalCode).textFieldStyle(.roundedBorder).frame(width: 80)
                        TextField("Country", text: $address.country).textFieldStyle(.roundedBorder).frame(width: 110)
                    }
                }
                .padding(.bottom, 2)
            }
            addButton("Add Address") {
                edit.postalAddresses.append(PostalAddressSnapshot())
            }
        }
    }

    private var birthdaySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionLabel("BIRTHDAY")
            HStack(spacing: Theme.Spacing.sm) {
                Toggle("Has birthday", isOn: $hasBirthday).platformCheckbox()
                if hasBirthday {
                    DatePicker("", selection: $birthday, displayedComponents: .date).labelsHidden()
                }
            }
        }
    }

    private var datesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionLabel("DATES")
            ForEach($edit.dates) { $entry in
                HStack(spacing: Theme.Spacing.xs) {
                    TextField("label", text: $entry.label)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    DatePicker("", selection: $entry.date, displayedComponents: .date).labelsHidden()
                    removeButton { edit.dates.removeAll { $0.id == entry.id } }
                    Spacer()
                }
            }
            addButton("Add Date") {
                edit.dates.append(ContactDateSnapshot())
            }
        }
    }

    private func labeledList(
        title: String,
        items: Binding<[LabeledValueSnapshot]>,
        valuePrompt: String,
        defaultLabel: String,
        labelPrompt: String = "label"
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionLabel(title)
            ForEach(items) { $item in
                HStack(spacing: Theme.Spacing.xs) {
                    TextField(labelPrompt, text: $item.label)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    TextField(valuePrompt, text: $item.value).textFieldStyle(.roundedBorder)
                    removeButton { items.wrappedValue.removeAll { $0.id == item.id } }
                }
            }
            addButton("Add") {
                items.wrappedValue.append(LabeledValueSnapshot(label: defaultLabel, value: ""))
            }
        }
    }

    // MARK: Small pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.cardCaption.weight(.semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle").foregroundStyle(Theme.Palette.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func addButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func save() async {
        saving = true
        var data = edit
        data.birthday = hasBirthday ? birthday : nil
        do {
            _ = try await brokers.contacts.saveContact(id: contact.id, edit: data)
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
