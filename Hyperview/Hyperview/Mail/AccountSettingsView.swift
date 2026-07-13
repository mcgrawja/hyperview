//
//  AccountSettingsView.swift
//  Unifyr
//
//  Per-account settings: IMAP/SMTP servers, password, badge label + color (used
//  in the unified mailboxes and the sidebar), and the email signature. Opened
//  from the account's context menu in the Mail sidebar.
//
//  The server fields matter more than they look: setup GUESSES imap.<your-domain>
//  for an unrecognized domain, which is wrong for any domain whose mail is really
//  hosted by iCloud or Google. Without an in-place edit the only way to fix that
//  is to delete and re-add the account — and a delete now tombstones the account
//  on every other device (MailAccountSync). So: edit, don't delete.
//

import SwiftUI
import SwiftData

struct AccountSettingsView: View {
    @Bindable var account: MailAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.mailService) private var mailService
    @Environment(\.isCompactLayout) private var isCompact

    @State private var badgeColor: Color = Theme.Palette.primary
    @State private var newPassword = ""
    /// Servers as they were on open — used to decide whether to drop the live
    /// connection so the next refresh dials the new host.
    @State private var originalServers: [String] = []

    private var domainFallback: String {
        account.emailAddress.split(separator: "@").last.map(String.init) ?? "mail"
    }

    private var currentServers: [String] {
        [account.imapHost, String(account.imapPort), account.smtpHost, String(account.smtpPort)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                serverSection
                passwordSection
                badgeSection
                signatureSection
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(idealWidth: 480, idealHeight: 520)
        // A fixed width would overflow an iPhone; only pin it where there's room.
        .frame(maxWidth: isCompact ? .infinity : 520)
        .background(Theme.Palette.background)
        .onAppear {
            badgeColor = Color(hexString: account.badgeColorHex) ?? Theme.Palette.primary
            originalServers = currentServers
        }
    }

    private var header: some View {
        HStack {
            Text(account.emailAddress)
                .font(Theme.Font.cardTitle)
            Spacer()
            Button("Done", action: save)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.primary)
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionLabel("SERVERS")
            serverRow("IMAP", host: $account.imapHost, port: $account.imapPort)
            serverRow("SMTP", host: $account.smtpHost, port: $account.smtpPort)
            Text("If your domain's mail is hosted by iCloud, these are imap.mail.me.com and smtp.mail.me.com — not imap.\(domainFallback). For Google, imap.gmail.com and smtp.gmail.com.")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionLabel("PASSWORD")
            SecureField("Leave blank to keep the current one", text: $newPassword)
                .textFieldStyle(.roundedBorder)
            Text("Stored in iCloud Keychain, so changing it here updates your other devices too.")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var badgeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionLabel("BADGE")
            HStack(spacing: Theme.Spacing.md) {
                TextField(domainFallback, text: $account.badgeLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                ColorPicker("", selection: $badgeColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: badgeColor) { _, newValue in
                        account.badgeColorHex = newValue.hexRGB ?? ""
                    }
                // Live preview of the badge as it appears in unified boxes.
                Text(account.badgeLabel.isEmpty ? domainFallback : account.badgeLabel)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(badgeColor.opacity(0.12), in: Capsule())
                Spacer()
            }
            Text("Shown on this account's messages in the unified mailboxes, and as its name in the sidebar.")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var signatureSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionLabel("SIGNATURE")
            TextEditor(text: $account.signature)
                .font(Theme.Font.cardBody)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.sm)
                .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .frame(minHeight: 90)
            Text("Appended to messages sent from this account. Leave empty for none.")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.cardCaption.weight(.semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
    }

    private func serverRow(_ label: String, host: Binding<String>, port: Binding<Int>) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(label)
                .font(Theme.Font.cardCaption)
                .frame(width: 44, alignment: .leading)
            TextField("host", text: host)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            TextField("port", value: port, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
        }
    }

    private func save() {
        let serversChanged = currentServers != originalServers

        if !newPassword.isEmpty {
            MailKeychain.setPassword(newPassword.trimmingCharacters(in: .whitespacesAndNewlines), for: account.id)
        }
        // Stamp the edit so MailAccountSync knows this copy is the newer one,
        // then publish it to the other devices.
        account.updatedAt = Date()
        try? context.save()
        MailAccountSync.shared.push()

        // A live connection is pinned to the OLD host, and a stale error banner
        // would outlive the fix — drop both so the next refresh dials fresh.
        if serversChanged || !newPassword.isEmpty, let mailService {
            let account = account
            Task {
                await mailService.disconnect(account)
                mailService.accountErrors[account.id] = nil
                await mailService.connect(account)
            }
        }
        dismiss()
    }
}
