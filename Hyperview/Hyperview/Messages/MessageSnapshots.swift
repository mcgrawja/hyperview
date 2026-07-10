//
//  MessageSnapshots.swift
//  Hyperview
//
//  Sendable value snapshots for the (experimental) Messages module — read
//  from the Messages database at ~/Library/Messages/chat.db. Same pattern as
//  Brokers/Snapshots.swift: framework-free, Codable-friendly.
//

import Foundation

/// One conversation from the Messages database.
nonisolated struct ChatSnapshot: Identifiable, Sendable, Hashable, Codable {
    /// `chat.ROWID`.
    let id: Int64
    /// `chat.guid` — e.g. "iMessage;-;+15551234567" or "iMessage;+;chat8...".
    /// Also the AppleScript `chat id` used to send into this conversation.
    var guid: String
    /// Group name if the chat has one; empty otherwise.
    var displayName: String
    /// `chat.chat_identifier` — the handle for 1:1 chats, chatNN for groups.
    var identifier: String
    /// "iMessage" or "SMS".
    var serviceName: String
    var isGroup: Bool
    /// Participant handles (phone numbers / Apple ID emails).
    var participants: [String]
    var lastDate: Date
    var lastPreview: String
    var lastFromMe: Bool
}

/// One message within a chat.
nonisolated struct MessageSnapshot: Identifiable, Sendable, Hashable, Codable {
    /// `message.ROWID`.
    let id: Int64
    var text: String
    var date: Date
    var isFromMe: Bool
    /// Sender handle for incoming messages (nil for own messages).
    var senderHandle: String?
    var hasAttachment: Bool
}
