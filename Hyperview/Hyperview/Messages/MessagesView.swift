//
//  MessagesView.swift
//  Hyperview
//
//  Experimental Messages module: conversation list + transcript over the
//  read-only chat.db reader, sending via Messages.app automation. Explicitly a
//  WRAPPER — no typing indicators, read receipts, or tapbacks (those have no
//  public surface). Needs user-granted Full Disk Access; the setup screen
//  walks through the grant.
//

import SwiftUI
import AppKit

struct MessagesView: View {
    private enum Phase {
        case checking
        case needsAccess
        case ready
    }

    @Environment(\.brokers) private var brokers
    @Environment(\.messagesDB) private var sharedDatabase

    @State private var fallbackDatabase = MessagesDatabase()
    private var database: MessagesDatabase { sharedDatabase ?? fallbackDatabase }
    @State private var phase: Phase = .checking
    @State private var chats: [ChatSnapshot] = []
    @State private var selectedChatID: Int64?
    @State private var messages: [MessageSnapshot] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    /// handle (email lowercased / phone last-10-digits) → contact name.
    @State private var nameIndex: [String: String] = [:]
    /// Local pin/hide state (chat guids) — chat.db is read-only, so these
    /// live in Hyperview only and don't touch the Messages app.
    @State private var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "messages.pinnedChats") ?? [])
    @State private var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "messages.hiddenChats") ?? [])
    @State private var showingNewMessage = false
    @State private var enlargedImage: MessageAttachmentSnapshot?

    var body: some View {
        Group {
            switch phase {
            case .checking:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsAccess:
                accessPrompt
            case .ready:
                content
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Messages")
        .task { await start() }
        .toolbar {
            ToolbarItem {
                Button { showingNewMessage = true } label: { Image(systemName: "square.and.pencil") }
                    .help("New Message")
                    .disabled(phase != .ready)
            }
            if !hidden.isEmpty {
                ToolbarItem {
                    Button("Unhide All (\(hidden.count))") {
                        hidden = []
                        persistChatState()
                    }
                    .help("Show all hidden conversations")
                }
            }
        }
        .sheet(isPresented: $showingNewMessage) {
            NewMessageSheet { handle, text in
                try MessagesSender.send(text, toHandle: handle)
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    chats = await database.chats()
                    // Select the (possibly brand-new) conversation.
                    let digits = String(handle.filter(\.isNumber).suffix(10))
                    if let match = chats.first(where: { chat in
                        chat.participants.contains { participant in
                            participant.caseInsensitiveCompare(handle) == .orderedSame
                                || (!digits.isEmpty && participant.filter(\.isNumber).hasSuffix(digits))
                        }
                    }) {
                        selectedChatID = match.id
                    }
                }
            }
        }
        .sheet(item: $enlargedImage) { attachment in
            ImageAttachmentViewer(attachment: attachment)
        }
    }

    private func persistChatState() {
        UserDefaults.standard.set(Array(pinned), forKey: "messages.pinnedChats")
        UserDefaults.standard.set(Array(hidden), forKey: "messages.hiddenChats")
    }

    // MARK: Access onboarding

    private var accessPrompt: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "message.badge.filled.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Palette.primary)
                Text("Connect Messages")
                    .font(Theme.Font.cardTitle)
            }
            Text("Hyperview reads your iMessage history directly from the Messages database, which macOS protects behind Full Disk Access. Reading is local and read-only; sending goes through the Messages app itself.")
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                stepLine("1", "Click “Open System Settings” below (Privacy & Security → Full Disk Access).")
                stepLine("2", "Turn on **Hyperview** — use the ＋ button and pick /Applications/Hyperview.app if it isn't listed.")
                stepLine("3", "Come back and click “Check Again”. If it still doesn't connect, quit and reopen Hyperview once.")
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            HStack(spacing: Theme.Spacing.sm) {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.primary)
                Button("Check Again") {
                    Task { await start() }
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stepLine(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(number)
                .font(Theme.Font.cardCaption.weight(.bold))
                .foregroundStyle(Theme.Palette.textOnAccent)
                .frame(width: 18, height: 18)
                .background(Theme.Palette.primary, in: Circle())
            Text(.init(text))
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Layout

    private var content: some View {
        HSplitView {
            chatList
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
            transcript
                .frame(minWidth: 380)
        }
        .task(id: selectedChatID) {
            await loadTranscript()
        }
        // Poll for new messages — chat.db has no public change feed.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await refresh()
            }
        }
    }

    private var chatList: some View {
        let visible = chats.filter { !hidden.contains($0.guid) }
        let pinnedChats = visible.filter { pinned.contains($0.guid) }
        let rest = visible.filter { !pinned.contains($0.guid) }
        return List(selection: $selectedChatID) {
            if !pinnedChats.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedChats) { chat in
                        chatRow(chat)
                    }
                }
            }
            Section(pinnedChats.isEmpty ? "" : "Messages") {
                ForEach(rest) { chat in
                    chatRow(chat)
                }
            }
        }
        .listStyle(.inset)
        .background(Theme.Palette.surface)
    }

    private func chatRow(_ chat: ChatSnapshot) -> some View {
        ChatRow(chat: chat, title: title(for: chat), isPinned: pinned.contains(chat.guid))
            .tag(chat.id)
            .contextMenu {
                Button(pinned.contains(chat.guid) ? "Unpin" : "Pin") {
                    if pinned.contains(chat.guid) {
                        pinned.remove(chat.guid)
                    } else {
                        pinned.insert(chat.guid)
                    }
                    persistChatState()
                }
                Divider()
                Button("Hide Conversation") {
                    hidden.insert(chat.guid)
                    pinned.remove(chat.guid)
                    if selectedChatID == chat.id { selectedChatID = nil }
                    persistChatState()
                }
                // Honest label: chat.db is read-only and Messages has no
                // scriptable delete — hiding is local to Hyperview.
                Text("Hiding only affects Hyperview — the conversation stays in Messages.")
            }
    }

    @ViewBuilder
    private var transcript: some View {
        if let chat = selectedChat {
            VStack(spacing: 0) {
                transcriptHeader(chat)
                Divider().overlay(Theme.Palette.separator)
                transcriptScroll(chat)
                Divider().overlay(Theme.Palette.separator)
                composer(chat)
            }
        } else {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "message")
                    .font(.system(size: 42))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Select a conversation")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transcriptHeader(_ chat: ChatSnapshot) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title(for: chat))
                .font(Theme.Font.cardTitle)
                .lineLimit(1)
            Text(chat.serviceName)
                .font(Theme.Font.cardCaption)
                .foregroundStyle(Theme.Palette.textOnAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    chat.serviceName == "SMS" ? Color.green.opacity(0.8) : Theme.Palette.primary.opacity(0.8),
                    in: Capsule()
                )
            Spacer()
        }
        .padding(Theme.Spacing.md)
    }

    private func transcriptScroll(_ chat: ChatSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(transcriptEntries(chat)) { entry in
                        switch entry.kind {
                        case .daySeparator(let date):
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .padding(.vertical, Theme.Spacing.sm)
                        case .sender(let name):
                            Text(name)
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, Theme.Spacing.md)
                                .padding(.top, 3)
                        case .message(let message):
                            MessageBubble(message: message) { attachment in
                                if attachment.isImage {
                                    enlargedImage = attachment
                                } else {
                                    saveAttachment(attachment)
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.md)
            }
            .onChange(of: messages.last?.id) { _, lastID in
                if let lastID {
                    proxy.scrollTo("msg-\(lastID)", anchor: .bottom)
                }
            }
            .onAppear {
                if let lastID = messages.last?.id {
                    proxy.scrollTo("msg-\(lastID)", anchor: .bottom)
                }
            }
        }
    }

    private func composer(_ chat: ChatSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let sendError {
                Text(sendError)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.danger)
            }
            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                Button {
                    attachFile(chat)
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .help("Send a file")
                TextField("iMessage", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(Theme.Spacing.sm)
                    .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                    .onSubmit { Task { await send(chat) } }
                Button {
                    Task { await send(chat) }
                } label: {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(
                                draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Theme.Palette.textSecondary
                                    : Theme.Palette.primary
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (sends via the Messages app)")
            }
        }
        .padding(Theme.Spacing.md)
    }

    // MARK: Transcript assembly

    private enum EntryKind {
        case daySeparator(Date)
        case sender(String)
        case message(MessageSnapshot)
    }

    private struct Entry: Identifiable {
        let id: String
        let kind: EntryKind
    }

    /// Messages interleaved with day separators and (in groups) sender names
    /// above each incoming run.
    private func transcriptEntries(_ chat: ChatSnapshot) -> [Entry] {
        var entries: [Entry] = []
        var lastDay: Date?
        var lastSender: String?
        let calendar = Calendar.current
        for message in messages {
            let day = calendar.startOfDay(for: message.date)
            if lastDay != day {
                entries.append(Entry(id: "day-\(day.timeIntervalSinceReferenceDate)", kind: .daySeparator(day)))
                lastDay = day
                lastSender = nil
            }
            if chat.isGroup, !message.isFromMe, let handle = message.senderHandle, handle != lastSender {
                entries.append(Entry(id: "sender-\(message.id)", kind: .sender(resolveName(handle))))
            }
            lastSender = message.isFromMe ? nil : message.senderHandle
            entries.append(Entry(id: "msg-\(message.id)", kind: .message(message)))
        }
        return entries
    }

    // MARK: Data

    private var selectedChat: ChatSnapshot? {
        chats.first { $0.id == selectedChatID }
    }

    private func start() async {
        phase = .checking
        guard await database.hasAccess() else {
            phase = .needsAccess
            return
        }
        await buildNameIndex()
        chats = await database.chats()
        if selectedChatID == nil { selectedChatID = chats.first?.id }
        phase = .ready
    }

    private func loadTranscript() async {
        guard let selectedChatID else {
            messages = []
            return
        }
        messages = await database.messages(chatID: selectedChatID)
    }

    /// Quiet poll: refresh the chat list; reload the open transcript only
    /// when its newest ROWID moved (avoids scroll jumps).
    private func refresh() async {
        guard phase == .ready else { return }
        chats = await database.chats()
        guard let selectedChatID else { return }
        let latest = await database.latestMessageID(chatID: selectedChatID)
        if latest != messages.last?.id {
            messages = await database.messages(chatID: selectedChatID)
        }
    }

    private func attachFile(_ chat: ChatSnapshot) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to send"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sendError = nil
        do {
            try MessagesSender.sendFile(
                url.path,
                chatGUID: chat.guid,
                fallbackHandle: chat.isGroup ? nil : chat.participants.first ?? chat.identifier,
                service: chat.serviceName
            )
            Task {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
            }
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func send(_ chat: ChatSnapshot) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        sendError = nil
        do {
            try MessagesSender.send(
                text,
                chatGUID: chat.guid,
                fallbackHandle: chat.isGroup ? nil : chat.participants.first ?? chat.identifier,
                service: chat.serviceName
            )
            draft = ""
            // The sent message lands in chat.db a moment later.
            try? await Task.sleep(for: .seconds(1.2))
            await refresh()
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }

    /// Non-image attachments: other apps can't read ~/Library/Messages (TCC),
    /// so "open" means saving a copy where the user chooses first.
    private func saveAttachment(_ attachment: MessageAttachmentSnapshot) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: attachment.path), to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            sendError = "Couldn't save the attachment."
        }
    }

    // MARK: Contact names

    /// Handles are phone numbers / emails; borrow Contacts for display names.
    private func buildNameIndex() async {
        guard brokers.contacts.authorization == .authorized || brokers.contacts.authorization == .limited,
              let contacts = try? await brokers.contacts.fetch(BrokerQuery(limit: 3000)) else { return }
        var index: [String: String] = [:]
        for contact in contacts {
            let name = contact.displayName
            guard name != "No Name" else { continue }
            for email in contact.emailAddresses {
                index[email.lowercased()] = name
            }
            for phone in contact.phoneNumbers {
                let digits = phone.filter(\.isNumber)
                guard digits.count >= 7 else { continue }
                index[String(digits.suffix(10))] = name
            }
        }
        nameIndex = index
    }

    private func resolveName(_ handle: String) -> String {
        if handle.contains("@") {
            return nameIndex[handle.lowercased()] ?? handle
        }
        let digits = handle.filter(\.isNumber)
        if digits.count >= 7, let name = nameIndex[String(digits.suffix(10))] {
            return name
        }
        return handle
    }

    private func title(for chat: ChatSnapshot) -> String {
        if !chat.displayName.isEmpty { return chat.displayName }
        let names = chat.participants.map(resolveName)
        if !names.isEmpty { return names.joined(separator: ", ") }
        return chat.identifier.isEmpty ? "Unknown" : resolveName(chat.identifier)
    }
}

// MARK: - Rows & bubbles

private struct ChatRow: View {
    let chat: ChatSnapshot
    let title: String
    var isPinned: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            ZStack {
                Circle()
                    .fill(Theme.Palette.primary.opacity(0.25))
                    .frame(width: 34, height: 34)
                if chat.isGroup {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.primary)
                } else {
                    Text(initials)
                        .font(Theme.Font.cardCaption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primary)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(Theme.Font.cardBody.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(relativeDate)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Text((chat.lastFromMe ? "You: " : "") + chat.lastPreview)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var initials: String {
        let parts = title.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var relativeDate: String {
        if Calendar.current.isDateInToday(chat.lastDate) {
            return chat.lastDate.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(chat.lastDate) {
            return "Yesterday"
        }
        return chat.lastDate.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct MessageBubble: View {
    let message: MessageSnapshot
    var onAttachmentTap: (MessageAttachmentSnapshot) -> Void = { _ in }

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                ForEach(message.attachments) { attachment in
                    AttachmentView(attachment: attachment)
                        .onTapGesture { onAttachmentTap(attachment) }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(Theme.Font.cardBody)
                        .foregroundStyle(message.isFromMe ? Theme.Palette.textOnAccent : Theme.Palette.textPrimary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            message.isFromMe ? Theme.Palette.primary : Theme.Palette.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .textSelection(.enabled)
                } else if message.attachments.isEmpty && message.hasAttachment {
                    // The file is gone from disk (e.g. purged by Messages).
                    Text("📎 Attachment unavailable")
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .help(message.date.formatted(date: .abbreviated, time: .shortened))
            if !message.isFromMe { Spacer(minLength: 60) }
        }
        .id("msg-\(message.id)")
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }
}

/// One attachment inside a bubble: inline preview for images, a labeled chip
/// for everything else.
private struct AttachmentView: View {
    let attachment: MessageAttachmentSnapshot
    @State private var image: NSImage?

    var body: some View {
        Group {
            if attachment.isImage {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.Palette.surfaceRaised)
                        .frame(width: 160, height: 110)
                        .overlay(ProgressView().controlSize(.small))
                        .task {
                            image = NSImage(contentsOfFile: attachment.path)
                        }
                }
            } else {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(Theme.Palette.primary)
                    Text(attachment.name)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                .help("Save…")
            }
        }
        .contentShape(Rectangle())
    }
}

/// Full-size image viewer for a tapped image attachment.
private struct ImageAttachmentViewer: View {
    let attachment: MessageAttachmentSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let image = NSImage(contentsOfFile: attachment.path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 900, maxHeight: 620)
            } else {
                Text("Couldn't load the image.")
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 400, height: 200)
            }
            HStack {
                Text(attachment.name)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Spacer()
                Button("Save…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = attachment.name
                    if panel.runModal() == .OK, let destination = panel.url {
                        try? FileManager.default.removeItem(at: destination)
                        try? FileManager.default.copyItem(at: URL(fileURLWithPath: attachment.path), to: destination)
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Palette.background)
    }
}

/// Compose a message to a new recipient: search contacts or type a raw
/// phone/email handle.
private struct NewMessageSheet: View {
    /// (handle, text) — throws on send failure.
    let onSend: (String, String) throws -> Void

    @Environment(\.brokers) private var brokers
    @Environment(\.dismiss) private var dismiss

    @State private var recipientQuery = ""
    @State private var chosenHandle: String?
    @State private var suggestions: [(name: String, handle: String)] = []
    @State private var text = ""
    @State private var errorText: String?

    private var effectiveHandle: String {
        chosenHandle ?? recipientQuery.trimmingCharacters(in: .whitespaces)
    }

    private var handleLooksSendable: Bool {
        let handle = effectiveHandle
        return handle.contains("@") || handle.filter(\.isNumber).count >= 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("New Message").font(Theme.Font.cardTitle)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("To:")
                        .foregroundStyle(Theme.Palette.textSecondary)
                    TextField("Name, phone, or email", text: $recipientQuery)
                        .textFieldStyle(.plain)
                        .onChange(of: recipientQuery) { _, _ in
                            chosenHandle = nil
                            Task { await searchContacts() }
                        }
                    if chosenHandle != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Palette.primary)
                    }
                }
                .padding(Theme.Spacing.sm)
                .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))

                if chosenHandle == nil, !suggestions.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                                Button {
                                    chosenHandle = suggestion.handle
                                    recipientQuery = "\(suggestion.name) — \(suggestion.handle)"
                                } label: {
                                    HStack {
                                        Text(suggestion.name).font(Theme.Font.cardBody)
                                        Spacer()
                                        Text(suggestion.handle)
                                            .font(Theme.Font.cardCaption)
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, Theme.Spacing.sm)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                    .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
            }

            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(Theme.Spacing.sm)
                .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))

            if let errorText {
                Text(errorText)
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.danger)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button("Send") {
                    do {
                        try onSend(effectiveHandle, text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!handleLooksSendable || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420)
        .background(Theme.Palette.background)
    }

    private func searchContacts() async {
        let query = recipientQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, !query.contains("@"), query.filter(\.isNumber).count < 7 else {
            suggestions = []
            return
        }
        let contacts = (try? await brokers.contacts.fetch(BrokerQuery(searchText: query, limit: 8))) ?? []
        suggestions = contacts.flatMap { contact in
            (contact.phoneNumbers + contact.emailAddresses).map { (name: contact.displayName, handle: $0) }
        }
    }
}
