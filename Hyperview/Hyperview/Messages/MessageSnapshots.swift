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
    /// "iMessage" or "SMS" — derived from the MOST RECENT message's own
    /// service, not the chat row's static `service_name` (which is often the
    /// SMS-fallback variant even for iMessage threads).
    var serviceName: String
    var isGroup: Bool
    /// Participant handles (phone numbers / Apple ID emails).
    var participants: [String]
    var lastDate: Date
    var lastPreview: String
    var lastFromMe: Bool
    /// Every chat.ROWID merged into this one conversation. Apple stores a
    /// person's iMessage and SMS threads as separate chat rows; we merge them
    /// (like Messages does) and load the transcript across all of them.
    var memberChatIDs: [Int64] = []
}

/// A file attached to a message (from the `attachment` table).
nonisolated struct MessageAttachmentSnapshot: Identifiable, Sendable, Hashable, Codable {
    /// `attachment.ROWID`.
    let id: Int64
    /// Absolute on-disk path (inside ~/Library/Messages/Attachments).
    var path: String
    var mimeType: String
    /// Original filename for display/saving.
    var name: String

    var isImage: Bool {
        mimeType.hasPrefix("image/") && !mimeType.contains("heic-sequence")
    }
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
    var attachments: [MessageAttachmentSnapshot] = []
    /// Tapbacks on this message as emoji ("❤️", "👍", custom emoji…), one per
    /// reaction. Display-only — sending reactions has no public surface.
    var reactions: [String] = []
    /// This message's own service ("iMessage" or "SMS"), so a green SMS
    /// bubble can sit inside an otherwise-blue iMessage thread — as Apple's
    /// app shows it.
    var service: String = "iMessage"

    var isSMS: Bool { service.caseInsensitiveCompare("SMS") == .orderedSame }
}
