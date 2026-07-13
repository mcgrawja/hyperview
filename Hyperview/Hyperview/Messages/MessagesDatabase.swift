#if os(macOS)
//
//  MessagesDatabase.swift
//  Hyperview
//
//  Read-only access to the Messages history at ~/Library/Messages/chat.db
//  (SQLite). Requires BOTH the sandbox read exception in the entitlements AND
//  user-granted Full Disk Access (TCC) — `hasAccess` distinguishes the states
//  so the UI can walk the user through the grant.
//
//  This is an UNSUPPORTED Apple surface: the schema is stable in practice but
//  can change in any macOS update, so every query degrades to empty results
//  rather than crashing. Message text lives in `text` when present, otherwise
//  in `attributedBody` — a typedstream-archived NSAttributedString that
//  TypedStreamText decodes heuristically.
//

import Foundation
import SQLite3

actor MessagesDatabase {
    private var db: OpaquePointer?

    /// Real (non-container) home — the sandbox exception path is rooted there.
    nonisolated static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    nonisolated static var chatDBPath: String {
        realHome + "/Library/Messages/chat.db"
    }

    /// True once the database opens and answers a query. False means Full
    /// Disk Access hasn't been granted (or the grant needs an app relaunch).
    func hasAccess() -> Bool {
        if db != nil { return true }
        guard FileManager.default.isReadableFile(atPath: Self.chatDBPath) else { return false }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(Self.chatDBPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let opened = handle else {
            sqlite3_close(handle)
            return false
        }
        sqlite3_busy_timeout(opened, 1500)
        if probe(opened) {
            db = opened
            return true
        }
        sqlite3_close(opened)

        // WAL edge case: a read-only connection can't attach if no -shm file
        // exists (Messages not running since boot). immutable=1 reads a
        // point-in-time snapshot instead — fine for a viewer.
        let uri = "file:\(Self.chatDBPath)?immutable=1"
        var immutable: OpaquePointer?
        guard sqlite3_open_v2(uri, &immutable, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let snapshot = immutable else {
            sqlite3_close(immutable)
            return false
        }
        if probe(snapshot) {
            db = snapshot
            return true
        }
        sqlite3_close(snapshot)
        return false
    }

    private func probe(_ handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM chat", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: Chats

    /// Recent conversations, newest first — with iMessage/SMS chat rows for the
    /// same person MERGED into one, and the service badge taken from the most
    /// recent message rather than the chat's static `service_name`.
    func chats(limit: Int = 80) -> [ChatSnapshot] {
        guard let db, hasAccess() else { return [] }
        // Fetch extra raw rows so merging still yields ~limit conversations.
        let sql = """
        SELECT c.ROWID, c.guid, IFNULL(c.display_name, ''), IFNULL(c.chat_identifier, ''),
               c.style, MAX(m.date)
        FROM chat c
        JOIN chat_message_join j ON j.chat_id = c.ROWID
        JOIN message m ON m.ROWID = j.message_id
        WHERE m.item_type = 0
        GROUP BY c.ROWID
        ORDER BY MAX(m.date) DESC
        LIMIT \(limit * 3)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var raws: [ChatSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let chatID = sqlite3_column_int64(statement, 0)
            let style = sqlite3_column_int(statement, 4)
            let handles = participants(chatID: chatID)
            let info = lastMessageInfo(chatID: chatID)
            raws.append(ChatSnapshot(
                id: chatID,
                guid: columnString(statement, 1),
                displayName: columnString(statement, 2),
                identifier: columnString(statement, 3),
                serviceName: info.service,
                isGroup: style == 43, // 43 = group, 45 = 1:1
                participants: handles,
                lastDate: Self.appleDate(sqlite3_column_int64(statement, 5)),
                lastPreview: info.preview,
                lastFromMe: info.fromMe,
                memberChatIDs: [chatID]
            ))
        }

        // Merge rows that are the same conversation (a person's iMessage + SMS
        // threads). Group 1:1 chats by their single normalized handle; keep
        // group chats separate by guid.
        func mergeKey(_ chat: ChatSnapshot) -> String {
            if chat.isGroup { return "g:" + chat.guid }
            if let handle = chat.participants.first { return "h:" + Self.normalize(handle) }
            return "i:" + chat.identifier
        }
        var groups: [String: ChatSnapshot] = [:]
        for raw in raws {
            let key = mergeKey(raw)
            if var existing = groups[key] {
                existing.memberChatIDs.append(contentsOf: raw.memberChatIDs)
                // Keep the most-recent row as the representative (its guid is
                // the active service to reply on; its message drives the badge).
                if raw.lastDate > existing.lastDate {
                    let members = existing.memberChatIDs
                    existing = raw
                    existing.memberChatIDs = members
                }
                groups[key] = existing
            } else {
                groups[key] = raw
            }
        }
        return groups.values
            .sorted { $0.lastDate > $1.lastDate }
            .prefix(limit)
            .map { $0 }
    }

    /// Normalize a handle for merge-matching: emails lowercased, phone numbers
    /// reduced to their last 10 digits.
    private static func normalize(_ handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return digits.count >= 7 ? String(digits.suffix(10)) : handle
    }

    private func participants(chatID: Int64) -> [String] {
        guard let db else { return [] }
        let sql = """
        SELECT h.id FROM handle h
        JOIN chat_handle_join j ON j.handle_id = h.ROWID
        WHERE j.chat_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, chatID)
        var handles: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            handles.append(columnString(statement, 0))
        }
        return handles
    }

    private func lastMessageInfo(chatID: Int64) -> (preview: String, fromMe: Bool, service: String) {
        guard let db else { return ("", false, "iMessage") }
        let sql = """
        SELECT m.text, m.attributedBody, m.is_from_me, m.cache_has_attachments, IFNULL(m.service, 'iMessage')
        FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        WHERE j.chat_id = ? AND m.item_type = 0 AND m.associated_message_type = 0
        ORDER BY m.date DESC LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return ("", false, "iMessage") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, chatID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return ("", false, "iMessage") }
        let hasAttachment = sqlite3_column_int(statement, 3) != 0
        let text = messageText(
            plain: columnString(statement, 0),
            body: columnData(statement, 1),
            hasAttachment: hasAttachment
        )
        let preview = text.isEmpty && hasAttachment ? "📎 Attachment" : text
        let service = columnString(statement, 4)
        return (preview, sqlite3_column_int(statement, 2) != 0, service.isEmpty ? "iMessage" : service)
    }

    // MARK: Messages

    /// The most recent messages of a conversation, oldest → newest. Accepts
    /// ALL merged member chat IDs so a person's iMessage + SMS threads read as
    /// one transcript. Tapbacks/edits and group-event rows are skipped.
    func messages(chatIDs: [Int64], limit: Int = 300) -> [MessageSnapshot] {
        guard let db, hasAccess(), !chatIDs.isEmpty else { return [] }
        let placeholders = chatIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT DISTINCT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me,
               h.id, m.cache_has_attachments, m.guid, IFNULL(m.service, 'iMessage')
        FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE j.chat_id IN (\(placeholders)) AND m.item_type = 0 AND m.associated_message_type = 0
        ORDER BY m.date DESC
        LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        for (index, chatID) in chatIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatID)
        }

        var result: [MessageSnapshot] = []
        var guidToRowID: [String: Int64] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let hasAttachment = sqlite3_column_int(statement, 6) != 0
            let text = messageText(
                plain: columnString(statement, 1),
                body: columnData(statement, 2),
                hasAttachment: hasAttachment
            )
            if text.isEmpty && !hasAttachment { continue }
            let rowID = sqlite3_column_int64(statement, 0)
            let guid = columnString(statement, 7)
            if !guid.isEmpty { guidToRowID[guid] = rowID }
            let sender = columnString(statement, 5)
            let service = columnString(statement, 8)
            result.append(MessageSnapshot(
                id: rowID,
                text: text,
                date: Self.appleDate(sqlite3_column_int64(statement, 3)),
                isFromMe: sqlite3_column_int(statement, 4) != 0,
                senderHandle: sender.isEmpty ? nil : sender,
                hasAttachment: hasAttachment,
                service: service.isEmpty ? "iMessage" : service
            ))
        }
        var ordered = Array(result.reversed())
        attachInFiles(&ordered)
        attachReactions(&ordered, chatIDs: chatIDs, guidToRowID: guidToRowID)
        return ordered
    }

    /// Convenience for a single chat row.
    func messages(chatID: Int64, limit: Int = 300) -> [MessageSnapshot] {
        messages(chatIDs: [chatID], limit: limit)
    }

    /// Tapbacks live as separate rows: associated_message_type 2000–2005
    /// (❤️👍👎😂‼️❓, +2006 custom emoji) adds one, 3000-range removes it.
    /// Replayed in date order per (target, kind, sender) so removals cancel.
    private func attachReactions(_ messages: inout [MessageSnapshot], chatIDs: [Int64], guidToRowID: [String: Int64]) {
        guard let db, !guidToRowID.isEmpty, !chatIDs.isEmpty else { return }
        let placeholders = chatIDs.map { _ in "?" }.joined(separator: ",")
        // associated_message_emoji only exists on newer macOS — retry without.
        let withEmoji = """
        SELECT m.associated_message_guid, m.associated_message_type, m.is_from_me,
               IFNULL(h.id, ''), IFNULL(m.associated_message_emoji, '')
        FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE j.chat_id IN (\(placeholders)) AND m.associated_message_type >= 2000 AND m.associated_message_type < 4000
        ORDER BY m.date ASC
        LIMIT 1000
        """
        let withoutEmoji = withEmoji.replacingOccurrences(
            of: "IFNULL(m.associated_message_emoji, '')", with: "''"
        )
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, withEmoji, -1, &statement, nil) != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            guard sqlite3_prepare_v2(db, withoutEmoji, -1, &statement, nil) == SQLITE_OK else { return }
        }
        defer { sqlite3_finalize(statement) }
        for (index, chatID) in chatIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatID)
        }

        // (targetRowID, kind, sender) → emoji currently in effect.
        var active: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let rawTarget = columnString(statement, 0)
            let type = Int(sqlite3_column_int(statement, 1))
            let sender = sqlite3_column_int(statement, 2) != 0 ? "me" : columnString(statement, 3)
            let customEmoji = columnString(statement, 4)
            // "p:0/GUID" / "bp:GUID" → GUID.
            var targetGUID = rawTarget
            if let slash = targetGUID.lastIndex(of: "/") {
                targetGUID = String(targetGUID[targetGUID.index(after: slash)...])
            } else if let colon = targetGUID.lastIndex(of: ":") {
                targetGUID = String(targetGUID[targetGUID.index(after: colon)...])
            }
            guard let rowID = guidToRowID[targetGUID] else { continue }
            let kind = type % 1000
            let key = "\(rowID)|\(kind)|\(sender)"
            if type >= 3000 {
                active[key] = nil
            } else if let emoji = Self.tapbackEmoji(kind: kind, custom: customEmoji) {
                active[key] = "\(rowID)|\(emoji)"
            }
        }
        guard !active.isEmpty else { return }
        var byMessage: [Int64: [String]] = [:]
        for value in active.values {
            let parts = value.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let rowID = Int64(parts[0]) else { continue }
            byMessage[rowID, default: []].append(String(parts[1]))
        }
        for index in messages.indices {
            if let reactions = byMessage[messages[index].id] {
                messages[index].reactions = reactions.sorted()
            }
        }
    }

    private static func tapbackEmoji(kind: Int, custom: String) -> String? {
        switch kind {
        case 2000: return "❤️"
        case 2001: return "👍"
        case 2002: return "👎"
        case 2003: return "😂"
        case 2004: return "‼️"
        case 2005: return "❓"
        case 2006, 2007: return custom.isEmpty ? nil : custom
        default: return nil
        }
    }

    /// Attach on-disk files to the messages that have them (one join query).
    private func attachInFiles(_ messages: inout [MessageSnapshot]) {
        guard let db else { return }
        let ids = messages.filter(\.hasAttachment).map { String($0.id) }
        guard !ids.isEmpty else { return }
        let sql = """
        SELECT j.message_id, a.ROWID, IFNULL(a.filename, ''), IFNULL(a.mime_type, ''), IFNULL(a.transfer_name, '')
        FROM message_attachment_join j
        JOIN attachment a ON a.ROWID = j.attachment_id
        WHERE j.message_id IN (\(ids.joined(separator: ",")))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        var byMessage: [Int64: [MessageAttachmentSnapshot]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = sqlite3_column_int64(statement, 0)
            var path = columnString(statement, 2)
            guard !path.isEmpty else { continue }
            if path.hasPrefix("~") {
                path = Self.realHome + path.dropFirst()
            }
            let transferName = columnString(statement, 4)
            byMessage[messageID, default: []].append(MessageAttachmentSnapshot(
                id: sqlite3_column_int64(statement, 1),
                path: path,
                mimeType: columnString(statement, 3),
                name: transferName.isEmpty ? (path as NSString).lastPathComponent : transferName
            ))
        }
        for index in messages.indices {
            if let files = byMessage[messages[index].id] {
                messages[index].attachments = files
            }
        }
    }

    /// Unread incoming messages across all chats — the sidebar badge.
    func unreadCount() -> Int {
        guard hasAccess(), let db else { return 0 }
        let sql = """
        SELECT COUNT(*) FROM message
        WHERE is_read = 0 AND is_from_me = 0 AND item_type = 0 AND associated_message_type = 0
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// One newly-arrived incoming message, for notifications.
    nonisolated struct IncomingPing: Sendable {
        let rowID: Int64
        let handle: String
        let text: String
    }

    /// Incoming (not-from-me) messages with ROWID greater than `afterRowID`,
    /// oldest→newest. Returns the new high-water ROWID plus the pings. Passing
    /// `afterRowID == 0` returns only the current high-water mark and NO pings
    /// (so the first poll establishes a baseline without notifying history).
    func newIncoming(afterRowID: Int64, limit: Int = 10) -> (latest: Int64, pings: [IncomingPing]) {
        guard hasAccess(), let db else { return (afterRowID, []) }
        let highWater = latestOverallMessageID()
        guard afterRowID > 0, highWater > afterRowID else { return (highWater, []) }
        let sql = """
        SELECT m.ROWID, IFNULL(h.id, ''), m.text, m.attributedBody, m.cache_has_attachments
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.ROWID > ? AND m.is_from_me = 0 AND m.item_type = 0 AND m.associated_message_type = 0
        ORDER BY m.ROWID ASC
        LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return (highWater, []) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, afterRowID)
        var pings: [IncomingPing] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let hasAttachment = sqlite3_column_int(statement, 4) != 0
            let text = messageText(
                plain: columnString(statement, 2),
                body: columnData(statement, 3),
                hasAttachment: hasAttachment
            )
            pings.append(IncomingPing(
                rowID: sqlite3_column_int64(statement, 0),
                handle: columnString(statement, 1),
                text: text.isEmpty && hasAttachment ? "📎 Attachment" : text
            ))
        }
        return (highWater, pings)
    }

    /// Highest message ROWID overall — the message "clock".
    func latestOverallMessageID() -> Int64 {
        guard hasAccess(), let db else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(ROWID) FROM message", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    /// ROWID of the newest message across the conversation's member chats —
    /// cheap "anything new?" poll.
    func latestMessageID(chatIDs: [Int64]) -> Int64 {
        guard let db, hasAccess(), !chatIDs.isEmpty else { return 0 }
        let placeholders = chatIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT MAX(m.ROWID) FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        WHERE j.chat_id IN (\(placeholders))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        for (index, chatID) in chatIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatID)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    // MARK: - Helpers

    /// Message text with U+FFFC inline-attachment placeholders removed;
    /// empty for attachment-only messages (the UI renders the files).
    private func messageText(plain: String, body: Data?, hasAttachment: Bool) -> String {
        let raw: String
        if !plain.isEmpty {
            raw = plain
        } else if let body, let decoded = TypedStreamText.decode(body) {
            raw = decoded
        } else {
            raw = ""
        }
        return raw
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `message.date` is nanoseconds since 2001-01-01 on modern macOS
    /// (seconds on ancient exports).
    private static func appleDate(_ raw: Int64) -> Date {
        let interval = raw > 10_000_000_000 ? TimeInterval(raw) / 1_000_000_000 : TimeInterval(raw)
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func columnData(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

// MARK: - typedstream text extraction

/// Extracts the plain string from `message.attributedBody` — an
/// NSAttributedString archived in Apple's legacy "typedstream" format. Full
/// parsing isn't needed: the first string payload after the "NSString" class
/// marker IS the message text (length-prefixed: 1 byte, or 0x81 + UInt16 LE,
/// or 0x82 + UInt32 LE). Heuristic on purpose — returns nil rather than
/// guessing wrong.
nonisolated enum TypedStreamText {
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let needle = [UInt8]("NSString".utf8)
        guard let start = firstIndex(of: needle, in: bytes) else { return nil }

        // After the class name: version/marker bytes ending in '+' (0x2B),
        // then the length. Scan a small window instead of hardcoding offsets.
        var i = start + needle.count
        let windowEnd = min(i + 8, bytes.count)
        var foundMarker = false
        while i < windowEnd {
            if bytes[i] == 0x2B { foundMarker = true; i += 1; break }
            i += 1
        }
        guard foundMarker, i < bytes.count else { return nil }

        let first = bytes[i]
        var length: Int
        var payload: Int
        switch first {
        case 0x81:
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8)
            payload = i + 3
        case 0x82:
            guard i + 4 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8)
                | (Int(bytes[i + 3]) << 16) | (Int(bytes[i + 4]) << 24)
            payload = i + 5
        default:
            length = Int(first)
            payload = i + 1
        }
        guard length > 0, payload + length <= bytes.count else { return nil }
        return String(bytes: bytes[payload..<(payload + length)], encoding: .utf8)
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        for i in 0...limit where haystack[i] == needle[0] {
            var match = true
            for j in 1..<needle.count where haystack[i + j] != needle[j] {
                match = false
                break
            }
            if match { return i }
        }
        return nil
    }
}

#endif
