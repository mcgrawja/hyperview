//
//  AccountSetupView.swift
//  Unifyr
//
//  First-run mail account setup. Autodetects IMAP/SMTP servers from the email
//  domain (editable for other providers). The app password is written straight
//  to the Keychain (MailKeychain) — never to SwiftData (D9).
//

import SwiftUI
import SwiftData

struct AccountSetupView: View {
    /// Show a Cancel control (sheet presentation for adding another account).
    var showsCancel: Bool = false
    /// Called after the account is saved (or Cancel is tapped).
    var onComplete: (() -> Void)? = nil

    @Environment(\.modelContext) private var context

    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var imapHost = ""
    @State private var imapPort = 993
    @State private var smtpHost = ""
    @State private var smtpPort = 587
    @State private var showAdvanced = false
    /// DNS-backed server detection for the address being typed.
    @State private var detection: MailProvider.Detection?
    @State private var isDetecting = false
    /// What we last filled in ourselves. If the fields still match it, the user
    /// hasn't touched them and detection may overwrite; if they've diverged,
    /// they're hand-edited and we leave them alone. (Comparing beats an onChange
    /// flag, which can't tell our own programmatic fill from a real edit.)
    @State private var lastApplied: MailProvider.Settings?
    @State private var detectTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header

                field("Your name", text: $displayName, prompt: "Jason McGraw")
                field("Email address", text: $email, prompt: "you@example.com")
                    .onChange(of: email) { _, value in applyProvider(for: value) }
                secureField("App password", text: $password)

                Text("Use an app-specific password, not your login password. Gmail/iCloud/Outlook require one when two-factor auth is on.")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)

                detectionStatus

                DisclosureGroup("Server settings", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        serverRow("IMAP", host: $imapHost, port: $imapPort)
                        serverRow("SMTP", host: $smtpHost, port: $smtpPort)
                    }
                    .padding(.top, Theme.Spacing.sm)
                }
                .tint(Theme.Palette.primary)

                Button(action: save) {
                    Text("Add Account")
                        .font(Theme.Font.cardBody.weight(.medium))
                        .foregroundStyle(Theme.Palette.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(canSave ? Theme.Palette.primary : Theme.Palette.textSecondary,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)

                if showsCancel {
                    Button("Cancel") { onComplete?() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Palette.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Palette.primary)
            Text("Add a Mail Account")
                .font(Theme.Font.dashboardTitle)
            Text("Connect over IMAP/SMTP. Your messages stay on this device and are never synced to iCloud — only these settings sync, and the password rides iCloud Keychain, so your other devices set themselves up.")
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var canSave: Bool {
        !email.isEmpty && !password.isEmpty && !imapHost.isEmpty && !smtpHost.isEmpty
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label).font(Theme.Font.cardCaption).foregroundStyle(Theme.Palette.textSecondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label).font(Theme.Font.cardCaption).foregroundStyle(Theme.Palette.textSecondary)
            SecureField("••••••••", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func serverRow(_ label: String, host: Binding<String>, port: Binding<Int>) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(label).font(Theme.Font.cardCaption).frame(width: 44, alignment: .leading)
            TextField("host", text: host)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            TextField("port", value: port, format: .number).textFieldStyle(.roundedBorder).frame(width: 72)
        }
    }

    /// What detection found — or that the guessed server doesn't exist, which is
    /// the trap this whole path is here to close.
    @ViewBuilder
    private var detectionStatus: some View {
        if isDetecting {
            Label("Looking up \(domainOf(email))…", systemImage: "magnifyingglass")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else if let warning = detection?.warning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.danger)
        } else if let summary = detection?.summary {
            Label(summary, systemImage: "checkmark.circle")
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.primary)
        }
    }

    private func domainOf(_ email: String) -> String {
        email.split(separator: "@").last.map(String.init) ?? "your domain"
    }

    /// Fill the servers from the address: the instant table guess first, then a
    /// DNS check of who actually hosts the domain's mail. A domain like mcgraw.cc
    /// is an iCloud custom domain — imap.mcgraw.cc doesn't exist, and only its MX
    /// records reveal that the mailbox really lives at imap.mail.me.com.
    private func applyProvider(for email: String) {
        detectTask?.cancel()
        detection = nil

        if serversUntouched { apply(MailProvider.settings(for: email)) }

        // Wait for a plausible address before hitting DNS on every keystroke.
        let domain = domainOf(email)
        guard email.contains("@"), domain.contains(".") else {
            isDetecting = false
            return
        }

        isDetecting = true
        detectTask = Task {
            // Debounce: the address is probably still being typed.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }

            let result = await MailProvider.detect(for: email)
            guard !Task.isCancelled else { return }

            isDetecting = false
            detection = result
            guard serversUntouched else { return }
            apply(result.settings)
            // Open the fields when they need a human — i.e. the guessed server
            // doesn't exist and we have nothing better to offer.
            if result.warning != nil { showAdvanced = true }
        }
    }

    private var serversUntouched: Bool {
        guard let lastApplied else { return true }
        return imapHost == lastApplied.imapHost && imapPort == lastApplied.imapPort
            && smtpHost == lastApplied.smtpHost && smtpPort == lastApplied.smtpPort
    }

    private func apply(_ settings: MailProvider.Settings) {
        imapHost = settings.imapHost
        imapPort = settings.imapPort
        smtpHost = settings.smtpHost
        smtpPort = settings.smtpPort
        lastApplied = settings
    }

    /// Google displays app passwords as "xxxx xxxx xxxx xxxx"; copying keeps the
    /// separators — which are often NON-BREAKING spaces (U+00A0), so a plain
    /// space check misses them. If removing every kind of whitespace yields
    /// exactly 16 letters (Google's app-password shape), use that; otherwise
    /// only trim the ends and leave interior characters alone.
    private func cleanedPassword() -> String {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let condensed = String(trimmed.filter { !$0.isWhitespace })
        if condensed.count == 16, condensed.allSatisfy({ $0.isLetter && $0.isLowercase }) {
            return condensed
        }
        return trimmed
    }

    private func save() {
        let account = MailAccount(
            emailAddress: email.trimmingCharacters(in: .whitespaces),
            displayName: displayName,
            imapHost: imapHost,
            imapPort: imapPort,
            smtpHost: smtpHost,
            smtpPort: smtpPort
        )
        context.insert(account)
        try? context.save()
        MailKeychain.setPassword(cleanedPassword(), for: account.id)
        // Publish the settings so the other devices pick the account up; the
        // password rides iCloud Keychain under this same account id.
        MailAccountSync.shared.push()
        onComplete?()
    }
}

