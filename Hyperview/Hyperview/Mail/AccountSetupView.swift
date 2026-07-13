//
//  AccountSetupView.swift
//  Hyperview
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
            TextField("host", text: host).textFieldStyle(.roundedBorder)
            TextField("port", value: port, format: .number).textFieldStyle(.roundedBorder).frame(width: 72)
        }
    }

    private func applyProvider(for email: String) {
        let s = MailProvider.settings(for: email)
        imapHost = s.imapHost
        imapPort = s.imapPort
        smtpHost = s.smtpHost
        smtpPort = s.smtpPort
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

/// Common-provider IMAP/SMTP autodetection from the email domain.
enum MailProvider {
    static func settings(for email: String) -> (imapHost: String, imapPort: Int, smtpHost: String, smtpPort: Int) {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        switch domain {
        case "gmail.com", "googlemail.com":
            return ("imap.gmail.com", 993, "smtp.gmail.com", 587)
        case "icloud.com", "me.com", "mac.com":
            return ("imap.mail.me.com", 993, "smtp.mail.me.com", 587)
        case "outlook.com", "hotmail.com", "live.com", "msn.com":
            return ("outlook.office365.com", 993, "smtp.office365.com", 587)
        case "yahoo.com":
            return ("imap.mail.yahoo.com", 993, "smtp.mail.yahoo.com", 587)
        case "aol.com":
            return ("imap.aol.com", 993, "smtp.aol.com", 587)
        default:
            return ("imap.\(domain)", 993, "smtp.\(domain)", 587)
        }
    }
}
