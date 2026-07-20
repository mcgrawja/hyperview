//
//  MailSnapshots.swift
//  Unifyr
//
//  Sendable value types exchanged across the IMAP/SMTP client and MailBroker
//  boundaries. No framework or @Model types cross here; these are what the UI
//  renders and the future MCP mail tools serialize (§7).
//

import Foundation

/// Connection settings for one account. The password is passed separately (from
/// the Keychain) and never lives in this struct, so it can't be logged.
nonisolated struct MailServerConfig: Sendable {
    var host: String
    var port: Int
    var username: String
}

/// An IMAP mailbox as returned by LIST/STATUS.
nonisolated struct MailboxInfo: Sendable, Hashable {
    var path: String
    var displayName: String
    var unreadCount: Int
    var totalCount: Int
}

/// A message header summary (from ENVELOPE + FLAGS).
nonisolated struct MessageSummary: Sendable, Identifiable, Hashable {
    var uid: Int
    var subject: String
    var fromName: String
    var fromAddress: String
    var toDisplay: String
    /// Raw recipient addresses — used by Reply All.
    var toAddresses: [String]
    var ccAddresses: [String]
    /// RFC 5322 Message-ID for reply threading headers.
    var messageID: String?
    var date: Date
    var isSeen: Bool
    var isFlagged: Bool

    var id: Int { uid }
}

/// A decoded message body.
nonisolated struct MessageBody: Sendable {
    var text: String?
    var html: String?
    var attachments: [AttachmentPart] = []
}

/// One decoded attachment (or inline part) of a message.
nonisolated struct AttachmentPart: Sendable, Hashable {
    var filename: String
    var mimeType: String
    /// Content-ID for `cid:` inline references (images embedded in HTML).
    var contentID: String?
    var data: Data
}

/// An outgoing message to hand to the SMTP client.
nonisolated struct OutgoingMessage: Sendable {
    var fromAddress: String
    var fromName: String
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
    /// Message-ID being replied to → In-Reply-To/References headers.
    var inReplyTo: String? = nil
    var attachments: [OutgoingAttachment] = []
}

/// A file attached to an outgoing message.
nonisolated struct OutgoingAttachment: Sendable, Hashable {
    var filename: String
    var mimeType: String
    var data: Data
}

/// Errors surfaced across the mail boundary; framework errors are wrapped.
nonisolated enum MailError: Error, Sendable {
    case notConnected
    case authenticationFailed
    case commandFailed(String)
    case protocolError(String)
    case connectionClosed
    case timeout
    case missingPassword
}
