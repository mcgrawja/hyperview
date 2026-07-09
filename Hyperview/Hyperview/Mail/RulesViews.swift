//
//  RulesViews.swift
//  Hyperview
//
//  Editors for Smart Mailboxes (saved searches) and Rules (conditions →
//  actions). Both build on the shared ConditionFormView from MailFilters.
//

import SwiftUI
import SwiftData

// MARK: - Smart Mailbox editor

struct SmartMailboxEditorTarget: Identifiable {
    let id = UUID()
    var box: SmartMailbox?
}

struct SmartMailboxEditorView: View {
    let target: SmartMailboxEditorTarget
    let accounts: [MailAccount]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var color: Color = Theme.Palette.primary
    @State private var condition = MailCondition()

    private var isNew: Bool { target.box == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(isNew ? "New Smart Mailbox" : "Edit Smart Mailbox")
                .font(Theme.Font.cardTitle)

            HStack(spacing: Theme.Spacing.md) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
            }

            ConditionFormView(condition: $condition, accounts: accounts)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button(isNew ? "Create" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.primary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420)
        .background(Theme.Palette.background)
        .onAppear {
            if let box = target.box {
                name = box.name
                color = Color(hexString: box.colorHex) ?? Theme.Palette.primary
                condition = box.condition
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let hex = color.hexRGB ?? ""
        if let box = target.box {
            box.name = trimmed
            box.colorHex = hex
            box.condition = condition
        } else {
            context.insert(SmartMailbox(name: trimmed, colorHex: hex, condition: condition))
        }
        try? context.save()
        dismiss()
    }
}

// MARK: - Rules manager

struct RulesManagerView: View {
    let accounts: [MailAccount]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \MailRule.sortIndex) private var rules: [MailRule]

    @State private var editing: RuleEditorTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("Rules").font(Theme.Font.cardTitle)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.primary)
            }

            Text("Rules run on newly arrived Inbox messages when a mailbox syncs, in order.")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)

            List {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 180)

            Button {
                editing = RuleEditorTarget(rule: nil)
            } label: {
                Label("Add Rule", systemImage: "plus")
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 480, height: 380)
        .background(Theme.Palette.background)
        .sheet(item: $editing) { target in
            RuleEditorView(target: target, accounts: accounts)
        }
    }

    private func ruleRow(_ rule: MailRule) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { rule.isEnabled = $0; try? context.save() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(rule.name)
                .font(Theme.Font.cardBody)
                .foregroundStyle(rule.isEnabled ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            Spacer()
            Button("Edit") { editing = RuleEditorTarget(rule: rule) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.primary)
            Button {
                context.delete(rule)
                try? context.save()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

// MARK: - Rule editor

struct RuleEditorTarget: Identifiable {
    let id = UUID()
    var rule: MailRule?
}

struct RuleEditorView: View {
    let target: RuleEditorTarget
    let accounts: [MailAccount]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \MailTag.name) private var tags: [MailTag]
    @Query(sort: \Mailbox.sortIndex) private var mailboxes: [Mailbox]

    @State private var name = ""
    @State private var condition = MailCondition()
    @State private var action = RuleAction()

    private var isNew: Bool { target.rule == nil }

    /// Move-to targets require the condition to pin one account.
    private var moveTargets: [Mailbox] {
        guard let accountID = condition.accountID else { return [] }
        return mailboxes.filter { $0.accountID == accountID && $0.path.uppercased() != "INBOX" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text(isNew ? "New Rule" : "Edit Rule")
                    .font(Theme.Font.cardTitle)

                TextField("Rule name", text: $name)
                    .textFieldStyle(.roundedBorder)

                sectionLabel("IF (all that are set)")
                ConditionFormView(condition: $condition, accounts: accounts)

                sectionLabel("THEN")
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Toggle("Mark as read", isOn: $action.markRead)
                    Toggle("Flag", isOn: $action.flag)
                    Picker("Add tag", selection: $action.addTagID) {
                        Text("None").tag(UUID?.none)
                        ForEach(tags) { tag in
                            Text(tag.name).tag(Optional(tag.id))
                        }
                    }
                    Toggle("Move to Trash", isOn: $action.moveToTrash)
                    if moveTargets.isEmpty {
                        Picker("Move to mailbox", selection: $action.moveToMailboxPath) {
                            Text("Pick an account above to enable").tag("")
                        }
                        .disabled(true)
                    } else {
                        Picker("Move to mailbox", selection: $action.moveToMailboxPath) {
                            Text("Don't move").tag("")
                            ForEach(moveTargets) { box in
                                Text(box.displayName).tag(box.path)
                            }
                        }
                    }
                }

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Button(isNew ? "Create" : "Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Palette.primary)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || action.isEmpty)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: 440, height: 520)
        .background(Theme.Palette.background)
        .onAppear {
            if let rule = target.rule {
                name = rule.name
                condition = rule.condition
                action = rule.action
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.cardCaption.weight(.semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let rule = target.rule {
            rule.name = trimmed
            rule.condition = condition
            rule.action = action
        } else {
            let rule = MailRule(name: trimmed, condition: condition, action: action)
            rule.sortIndex = ((try? context.fetch(FetchDescriptor<MailRule>()))?.map(\.sortIndex).max() ?? -1) + 1
            context.insert(rule)
        }
        try? context.save()
        dismiss()
    }
}
