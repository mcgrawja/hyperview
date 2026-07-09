//
//  ComposeView.swift
//  Hyperview
//
//  Compose + send: new messages, Reply / Reply All / Forward (with quoted
//  original and In-Reply-To/References threading), and per-account signatures.
//  Sending is an outward, hard-to-reverse action, so it goes through an
//  explicit confirmation (§7 safety defaults; the future mail_draft MCP tool is
//  draft-only and routes any send through this same surface).
//

import SwiftUI
import UniformTypeIdentifiers

/// What the compose window starts from.
enum ComposeMode {
    case new
    case reply(MailMessage, all: Bool)
    case forward(MailMessage)
}

/// Identifiable wrapper so compose is presented with `.sheet(item:)`.
struct ComposeSheet: Identifiable {
    let id = UUID()
    let mode: ComposeMode
}

struct ComposeView: View {
    let accounts: [MailAccount]
    let service: MailService

    @Environment(\.dismiss) private var dismiss

    @State private var fromAccountID: UUID?
    @State private var to: String
    @State private var cc: String
    @State private var subject: String
    @State private var messageBody: String
    @State private var confirming = false
    @State private var sending = false
    @State private var errorText: String?
    @State private var attachments: [OutgoingAttachment] = []

    private let inReplyTo: String?
    private let showCC: Bool

    init(accounts: [MailAccount], defaultAccount: MailAccount?, service: MailService, mode: ComposeMode = .new) {
        self.accounts = accounts
        self.service = service
        let account = defaultAccount ?? accounts.first
        _fromAccountID = State(initialValue: account?.id)

        let signatureBlock = (account?.signature.isEmpty == false)
            ? "\n\n--\n\(account!.signature)"
            : ""

        switch mode {
        case .new:
            _to = State(initialValue: "")
            _cc = State(initialValue: "")
            _subject = State(initialValue: "")
            _messageBody = State(initialValue: signatureBlock)
            inReplyTo = nil
            showCC = false

        case .reply(let original, let all):
            _to = State(initialValue: original.fromAddress)
            let ccList: [String]
            if all {
                let own = account?.emailAddress.lowercased()
                let others = (original.toAddressList.split(separator: ",") + original.ccAddressList.split(separator: ","))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.lowercased() != own && $0.lowercased() != original.fromAddress.lowercased() }
                ccList = Array(Set(others)).sorted()
            } else {
                ccList = []
            }
            _cc = State(initialValue: ccList.joined(separator: ", "))
            _subject = State(initialValue: Self.prefixed("Re:", original.subject))
            _messageBody = State(initialValue: signatureBlock + Self.quoted(original))
            inReplyTo = original.messageID
            showCC = all

        case .forward(let original):
            _to = State(initialValue: "")
            _cc = State(initialValue: "")
            _subject = State(initialValue: Self.prefixed("Fwd:", original.subject))
            _messageBody = State(initialValue: signatureBlock + Self.forwarded(original))
            inReplyTo = nil
            showCC = false
        }
    }

    private var fromAccount: MailAccount? {
        accounts.first { $0.id == fromAccountID } ?? accounts.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Palette.separator)

            VStack(spacing: 0) {
                if accounts.count > 1 {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("From")
                            .font(Theme.Font.cardCaption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(width: 56, alignment: .leading)
                        Picker("", selection: $fromAccountID) {
                            ForEach(accounts) { account in
                                Text(account.emailAddress).tag(Optional(account.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
                    Divider().overlay(Theme.Palette.separator)
                }
                composeField("To", text: $to, prompt: "recipient@example.com")
                Divider().overlay(Theme.Palette.separator)
                if showCC || !cc.isEmpty {
                    composeField("Cc", text: $cc, prompt: "")
                    Divider().overlay(Theme.Palette.separator)
                }
                composeField("Subject", text: $subject, prompt: "Subject")
                Divider().overlay(Theme.Palette.separator)
                TextEditor(text: $messageBody)
                    .font(Theme.Font.cardBody)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.sm)

                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.sm) {
                            ForEach(attachments, id: \.self) { attachment in
                                HStack(spacing: Theme.Spacing.xs) {
                                    Image(systemName: "paperclip")
                                        .foregroundStyle(Theme.Palette.primary)
                                    Text(attachment.filename)
                                        .font(Theme.Font.cardCaption)
                                        .lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                        .font(Theme.Font.cardCaption)
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                    Button {
                                        attachments.removeAll { $0 == attachment }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)
            }
        }
        .frame(width: 560, height: 480)
        .background(Theme.Palette.background)
        .confirmationDialog("Send this message?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Send") { Task { await performSend() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To: \(to)")
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button(action: attachFiles) {
                Image(systemName: "paperclip")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Attach Files…")
            Spacer()
            Text(subject.isEmpty ? "New Message" : subject)
                .font(Theme.Font.cardTitle)
                .lineLimit(1)
            Spacer()
            Button {
                confirming = true
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    if sending { ProgressView().controlSize(.small) }
                    Text("Send")
                }
                .foregroundStyle(canSend ? Theme.Palette.primary : Theme.Palette.textSecondary)
                .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .disabled(!canSend || sending)
        }
        .padding(Theme.Spacing.md)
    }

    private var canSend: Bool {
        !to.isEmpty && to.contains("@")
    }

    private func composeField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(label)
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 56, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(Theme.Font.cardBody)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func attachFiles() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            attachments.append(OutgoingAttachment(
                filename: url.lastPathComponent,
                mimeType: mime,
                data: data
            ))
        }
        #endif
    }

    private func performSend() async {
        guard let account = fromAccount else { return }
        sending = true
        errorText = nil
        let outgoing = OutgoingMessage(
            fromAddress: account.emailAddress,
            fromName: account.displayName,
            to: Self.splitAddresses(to),
            cc: Self.splitAddresses(cc),
            subject: subject,
            body: messageBody,
            inReplyTo: inReplyTo,
            attachments: attachments
        )
        do {
            try await service.send(outgoing, account: account)
            sending = false
            dismiss()
        } catch {
            sending = false
            errorText = "Couldn't send: \(String(describing: error))"
        }
    }

    // MARK: - Prefill helpers

    private static func splitAddresses(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "Re:"/"Fwd:" without stacking prefixes.
    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }

    private static func plaintext(of message: MailMessage) -> String {
        if let text = message.bodyText, !text.isEmpty { return text }
        if let html = message.bodyHTML { return MailText.strip(html) }
        return ""
    }

    private static func quoted(_ original: MailMessage) -> String {
        let who = original.fromName.isEmpty ? original.fromAddress : original.fromName
        let when = original.date.formatted(date: .abbreviated, time: .shortened)
        let quotedLines = plaintext(of: original)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { "> " + $0 }
            .joined(separator: "\n")
        return "\n\nOn \(when), \(who) wrote:\n\(quotedLines)"
    }

    private static func forwarded(_ original: MailMessage) -> String {
        """


        ---------- Forwarded message ----------
        From: \(original.fromName) <\(original.fromAddress)>
        Date: \(original.date.formatted(date: .abbreviated, time: .shortened))
        Subject: \(original.subject)
        To: \(original.toRecipients)

        \(plaintext(of: original))
        """
    }
}
