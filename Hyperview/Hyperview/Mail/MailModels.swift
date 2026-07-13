//
//  MailModels.swift
//  Hyperview
//
//  §6 / D9 — the local mail cache. These @Models live in a SEPARATE, non-CloudKit
//  ModelContainer (see MailStore): mail re-syncs from the servers on each device
//  and must never enter the CloudKit private database. Credentials are NOT stored
//  here — the app password lives in the Keychain (see MailKeychain).
//

import Foundation
import SwiftData

/// A configured IMAP/SMTP account.
@Model
final class MailAccount {
    var id: UUID = UUID()
    var emailAddress: String = ""
    var displayName: String = ""

    var imapHost: String = ""
    var imapPort: Int = 993
    var smtpHost: String = ""
    var smtpPort: Int = 587

    /// Appended to outgoing messages when non-empty.
    var signature: String = ""

    /// Short word shown on this account's badge in unified views (and as its
    /// sidebar name). Empty → the email domain.
    var badgeLabel: String = ""
    /// Badge tint as "#RRGGBB". Empty → theme primary.
    var badgeColorHex: String = ""
    /// Sidebar disclosure state (collapsed by default).
    var isExpanded: Bool = false

    var createdAt: Date = Date()
    /// Last edit to the settings above. MailAccountSync resolves cross-device
    /// conflicts last-write-wins on this, so anything that mutates an account
    /// must bump it.
    var updatedAt: Date = Date()

    init(
        emailAddress: String = "",
        displayName: String = "",
        imapHost: String = "",
        imapPort: Int = 993,
        smtpHost: String = "",
        smtpPort: Int = 587
    ) {
        self.id = UUID()
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// A cached IMAP mailbox (folder).
@Model
final class Mailbox {
    var id: UUID = UUID()
    var accountID: UUID = UUID()
    /// IMAP mailbox path, e.g. "INBOX" or "[Gmail]/Sent Mail".
    var path: String = ""
    var displayName: String = ""
    var unreadCount: Int = 0
    var totalCount: Int = 0
    /// Presentation order in the sidebar.
    var sortIndex: Int = 0

    init(accountID: UUID, path: String, displayName: String) {
        self.id = UUID()
        self.accountID = accountID
        self.path = path
        self.displayName = displayName
    }
}

/// A user-defined tag (local to this device; mail cache is server-authoritative
/// but tags are Hyperview's own metadata).
@Model
final class MailTag {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = ""
    var sortIndex: Int = 0

    init(name: String, colorHex: String = "") {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
    }
}

/// Assignment of a tag to a message. Keyed by the RFC 5322 Message-ID header —
/// NOT the cache row — so tags survive cache purges and re-syncs (UIDs and
/// local rows are disposable; Message-ID is stable).
@Model
final class MailTagAssignment {
    var id: UUID = UUID()
    var tagID: UUID = UUID()
    var messageIDHeader: String = ""

    init(tagID: UUID, messageIDHeader: String) {
        self.id = UUID()
        self.tagID = tagID
        self.messageIDHeader = messageIDHeader
    }
}

/// A decoded attachment of a cached message (fetched with the body).
@Model
final class MailAttachment {
    var id: UUID = UUID()
    /// `MailMessage.id` this belongs to.
    var messageID: UUID = UUID()
    var filename: String = ""
    var mimeType: String = ""
    /// Content-ID for `cid:` inline images.
    var contentID: String? = nil

    @Attribute(.externalStorage)
    var data: Data = Data()

    init(messageID: UUID, filename: String, mimeType: String, contentID: String?, data: Data) {
        self.id = UUID()
        self.messageID = messageID
        self.filename = filename
        self.mimeType = mimeType
        self.contentID = contentID
        self.data = data
    }
}

/// A cached message. `bodyText`/`bodyHTML` are populated lazily on open.
@Model
final class MailMessage {
    var id: UUID = UUID()
    var accountID: UUID = UUID()
    var mailboxPath: String = ""
    /// IMAP UID within the mailbox (stable per mailbox).
    var uid: Int = 0

    var subject: String = ""
    var fromName: String = ""
    var fromAddress: String = ""
    var toRecipients: String = ""       // comma-joined display
    /// Raw addresses (comma-joined) — needed for Reply All.
    var toAddressList: String = ""
    var ccAddressList: String = ""
    /// RFC 5322 Message-ID — needed for In-Reply-To/References when replying.
    var messageID: String? = nil
    var date: Date = Date()

    var isSeen: Bool = false
    var isFlagged: Bool = false

    var snippet: String = ""
    var bodyText: String? = nil
    var bodyHTML: String? = nil
    var hasFetchedBody: Bool = false

    init(accountID: UUID, mailboxPath: String, uid: Int) {
        self.id = UUID()
        self.accountID = accountID
        self.mailboxPath = mailboxPath
        self.uid = uid
    }
}
