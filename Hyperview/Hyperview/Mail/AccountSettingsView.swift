//
//  AccountSettingsView.swift
//  Hyperview
//
//  Per-account settings: badge label + color (used in unified mailboxes and
//  the sidebar) and the email signature. Opened from the account's context
//  menu in the Mail sidebar.
//

import SwiftUI
import SwiftData

struct AccountSettingsView: View {
    @Bindable var account: MailAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var badgeColor: Color = Theme.Palette.primary

    private var domainFallback: String {
        account.emailAddress.split(separator: "@").last.map(String.init) ?? "mail"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text(account.emailAddress)
                    .font(Theme.Font.cardTitle)
                Spacer()
                Button("Done") {
                    // Stamp the edit so MailAccountSync knows this copy is the
                    // newer one, then publish it to the other devices.
                    account.updatedAt = Date()
                    try? context.save()
                    MailAccountSync.shared.push()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.primary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("BADGE")
                    .font(Theme.Font.cardCaption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
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

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("SIGNATURE")
                    .font(Theme.Font.cardCaption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
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
        .padding(Theme.Spacing.lg)
        .frame(width: 480, height: 380)
        .background(Theme.Palette.background)
        .onAppear {
            badgeColor = Color(hexString: account.badgeColorHex) ?? Theme.Palette.primary
        }
    }
}
