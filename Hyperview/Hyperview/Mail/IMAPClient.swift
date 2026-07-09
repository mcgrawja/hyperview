//
//  IMAPClient.swift
//  Hyperview
//
//  A from-scratch IMAP client (RFC 3501) over Network.framework (D9 — no
//  third-party SDKs). Implements the read path needed for a working inbox:
//  login, LIST + STATUS, SELECT, FETCH (ENVELOPE/FLAGS summaries + full body),
//  UID SEARCH, and \Seen flagging. One actor owns one connection.
//

import Foundation

actor IMAPClient {
    private let config: MailServerConfig
    private var socket: SocketConnection?
    private var tagCounter = 0
    private var selectedMailbox: String?

    init(config: MailServerConfig) {
        self.config = config
    }

    // MARK: Connection lifecycle

    func connect() async throws {
        let socket = SocketConnection(host: config.host, port: config.port, useTLS: true)
        try await socket.start()
        self.socket = socket
        _ = try await readResponsePart() // server greeting
    }

    func login(password: String) async throws {
        let response = try await command("LOGIN \(quoted(config.username)) \(quoted(password))")
        if response.ok { return }
        MailLog.log("[IMAP] LOGIN rejected: \(response.text) — falling back to AUTHENTICATE PLAIN")
        try await authenticatePlain(password: password)
    }

    /// SASL PLAIN (RFC 4616) via continuation — some servers/policies accept it
    /// where the legacy LOGIN command is refused.
    private func authenticatePlain(password: String) async throws {
        guard let socket else { throw MailError.notConnected }
        let tag = nextTag()
        MailLog.log("[IMAP] > \(tag) AUTHENTICATE PLAIN")
        try await socket.send("\(tag) AUTHENTICATE PLAIN\r\n")

        let continuation = try await readResponsePart()
        let contStr = String(decoding: continuation, as: UTF8.self)
        guard contStr.hasPrefix("+") else {
            MailLog.log("[IMAP] AUTHENTICATE PLAIN refused: \(contStr.prefix(200))")
            throw MailError.authenticationFailed
        }

        let credentials = Data("\u{0}\(config.username)\u{0}\(password)".utf8).base64EncodedString()
        try await socket.send(credentials + "\r\n")
        while true {
            let part = try await readResponsePart()
            let str = String(decoding: part, as: UTF8.self)
            if str.hasPrefix("\(tag) ") {
                let rest = String(str.dropFirst(tag.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                MailLog.log("[IMAP] < \(tag) \(rest.prefix(200))")
                guard rest.uppercased().hasPrefix("OK") else { throw MailError.authenticationFailed }
                return
            }
        }
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        await socket?.close()
        socket = nil
    }

    // MARK: Mailboxes

    func listMailboxes() async throws -> [MailboxInfo] {
        let response = try await command("LIST \"\" \"*\"")
        guard response.ok else { throw MailError.commandFailed("LIST") }

        var boxes: [MailboxInfo] = []
        for part in response.untagged {
            var parser = IMAPParser(dropPrefix(part, after: "LIST"))
            let tokens = parser.parseAll()
            // tokens: (flags) "sep" name
            guard tokens.count >= 3 else { continue }
            let flags = (tokens[0].listValue ?? []).compactMap { $0.stringValue?.lowercased() }
            if flags.contains("\\noselect") { continue }
            guard let path = tokens.last?.stringValue, !path.isEmpty else { continue }
            boxes.append(MailboxInfo(path: path, displayName: displayName(for: path), unreadCount: 0, totalCount: 0))
        }
        return boxes
    }

    /// MESSAGES + UNSEEN counts for a mailbox (best-effort).
    func status(_ path: String) async -> (total: Int, unread: Int) {
        guard let response = try? await command("STATUS \(quoted(path)) (MESSAGES UNSEEN)"), response.ok else {
            return (0, 0)
        }
        var total = 0, unread = 0
        for part in response.untagged {
            var parser = IMAPParser(part)
            let tokens = parser.parseAll()
            guard let list = tokens.first(where: { $0.listValue != nil })?.listValue else { continue }
            var i = 0
            while i + 1 < list.count {
                let key = list[i].stringValue?.uppercased()
                if key == "MESSAGES" { total = list[i + 1].intValue ?? 0 }
                if key == "UNSEEN" { unread = list[i + 1].intValue ?? 0 }
                i += 2
            }
        }
        return (total, unread)
    }

    @discardableResult
    func select(_ path: String) async throws -> Int {
        let response = try await command("SELECT \(quoted(path))")
        guard response.ok else { throw MailError.commandFailed("SELECT \(path)") }
        selectedMailbox = path
        var exists = 0
        for part in response.untagged {
            let str = String(decoding: part, as: UTF8.self)
            if str.uppercased().contains(" EXISTS"), let n = firstNumber(in: str) { exists = n }
        }
        return exists
    }

    // MARK: Messages

    /// Most recent `limit` message summaries in `path`, newest first.
    func fetchSummaries(path: String, limit: Int = 50) async throws -> [MessageSummary] {
        let exists = try await select(path) // always refresh EXISTS for new mail
        guard exists > 0 else { return [] }
        let lo = max(1, exists - limit + 1)
        let response = try await command("FETCH \(lo):\(exists) (UID FLAGS INTERNALDATE ENVELOPE)")
        guard response.ok else { throw MailError.commandFailed("FETCH") }
        let summaries = response.untagged.compactMap(parseSummary)
        return summaries.sorted { $0.uid > $1.uid }
    }

    /// UID SEARCH then fetch matching summaries (newest `limit`).
    func search(path: String, query: String, limit: Int = 50) async throws -> [MessageSummary] {
        try await ensureSelected(path)
        let response = try await command("UID SEARCH TEXT \(quoted(query))")
        guard response.ok else { throw MailError.commandFailed("SEARCH") }
        var uids: [Int] = []
        for part in response.untagged {
            let str = String(decoding: part, as: UTF8.self)
            guard str.uppercased().contains("SEARCH") else { continue }
            uids += str.split(separator: " ").compactMap { Int($0) }
        }
        guard !uids.isEmpty else { return [] }
        let recent = uids.suffix(limit).map(String.init).joined(separator: ",")
        let fetch = try await command("UID FETCH \(recent) (UID FLAGS INTERNALDATE ENVELOPE)")
        guard fetch.ok else { throw MailError.commandFailed("UID FETCH") }
        return fetch.untagged.compactMap(parseSummary).sorted { $0.uid > $1.uid }
    }

    /// Full body of one message, parsed to text/html.
    func fetchBody(path: String, uid: Int) async throws -> MessageBody {
        try await ensureSelected(path)
        let response = try await command("UID FETCH \(uid) (BODY.PEEK[])")
        guard response.ok else { throw MailError.commandFailed("UID FETCH BODY") }
        for part in response.untagged where String(decoding: part, as: UTF8.self).uppercased().contains("FETCH") {
            if let raw = extractLiteral(from: part) {
                let head = String(decoding: raw.prefix(160), as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\n", with: "\\n")
                MailLog.log("[IMAP] body literal head: \(head)")
                return MIMEParser.parse(raw)
            }
        }
        return MessageBody(text: nil, html: nil)
    }

    func markSeen(path: String, uid: Int) async throws {
        try await setFlag(path: path, uid: uid, flag: "\\Seen", on: true)
    }

    /// Set or clear a standard IMAP flag (\Seen, \Flagged, \Deleted, …).
    func setFlag(path: String, uid: Int, flag: String, on: Bool) async throws {
        try await ensureSelected(path)
        let response = try await command("UID STORE \(uid) \(on ? "+" : "-")FLAGS (\(flag))")
        guard response.ok else { throw MailError.commandFailed("STORE \(flag)") }
    }

    /// Move a message to another mailbox. Prefers UID MOVE (RFC 6851 — Gmail
    /// and iCloud both support it); falls back to COPY + \Deleted + EXPUNGE.
    func move(path: String, uid: Int, to destination: String) async throws {
        try await ensureSelected(path)
        let moved = try await command("UID MOVE \(uid) \(quoted(destination))")
        if moved.ok { return }
        MailLog.log("[IMAP] UID MOVE unsupported, using COPY+EXPUNGE fallback")
        let copied = try await command("UID COPY \(uid) \(quoted(destination))")
        guard copied.ok else { throw MailError.commandFailed("COPY to \(destination)") }
        _ = try await command("UID STORE \(uid) +FLAGS (\\Deleted)")
        let expunged = try await command("UID EXPUNGE \(uid)") // UIDPLUS
        if !expunged.ok { _ = try await command("EXPUNGE") }
    }

    // MARK: - Command engine

    private struct IMAPResponse {
        let ok: Bool
        let text: String
        let untagged: [Data]
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "A%04d", tagCounter)
    }

    private func command(_ command: String) async throws -> IMAPResponse {
        guard let socket else { throw MailError.notConnected }
        let tag = nextTag()
        // Redact obvious credentials from command logs.
        let safeLog = command.uppercased().hasPrefix("LOGIN") ? "LOGIN ***" : command
        MailLog.log("[IMAP] > \(tag) \(safeLog)")
        try await socket.send("\(tag) \(command)\r\n")

        var untagged: [Data] = []
        while true {
            let part = try await readResponsePart()
            let str = String(decoding: part, as: UTF8.self)
            if str.hasPrefix("\(tag) ") {
                let rest = String(str.dropFirst(tag.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = rest.uppercased().hasPrefix("OK")
                // Log failures at full length — servers put the actionable reason
                // (and sometimes a help URL) in the NO/BAD text.
                MailLog.log("[IMAP] < \(tag) \(ok ? String(rest.prefix(80)) : rest) (\(untagged.count) untagged)")
                return IMAPResponse(ok: ok, text: rest, untagged: untagged)
            }
            untagged.append(part)
        }
    }

    /// Read one logical response, resolving IMAP `{n}` literals inline.
    private func readResponsePart() async throws -> Data {
        guard let socket else { throw MailError.notConnected }
        var part = Data()
        while true {
            let line = try await socket.readLine()
            part.append(line)
            if let n = trailingLiteralLength(line) {
                let literal = try await socket.readExact(n)
                part.append(literal)
            } else {
                break
            }
        }
        return part
    }

    /// SELECT only if not already on this mailbox (avoids redundant round trips
    /// when opening/flagging messages in the current mailbox).
    private func ensureSelected(_ path: String) async throws {
        if selectedMailbox == path { return }
        _ = try await select(path)
    }

    // MARK: - Parsing helpers

    private func parseSummary(_ part: Data) -> MessageSummary? {
        let str = String(decoding: part, as: UTF8.self)
        guard str.uppercased().contains("FETCH") else { return nil }
        var parser = IMAPParser(part)
        let tokens = parser.parseAll()
        guard let list = tokens.first(where: { $0.listValue != nil })?.listValue else { return nil }

        var uid = 0
        var flags: [String] = []
        var internalDate: String?
        var envelope: [IMAPToken]?
        var i = 0
        while i < list.count {
            guard let key = list[i].stringValue?.uppercased() else { i += 1; continue }
            switch key {
            case "UID" where i + 1 < list.count: uid = list[i + 1].intValue ?? 0; i += 2
            case "FLAGS" where i + 1 < list.count: flags = (list[i + 1].listValue ?? []).compactMap { $0.stringValue }; i += 2
            case "INTERNALDATE" where i + 1 < list.count: internalDate = list[i + 1].stringValue; i += 2
            case "ENVELOPE" where i + 1 < list.count: envelope = list[i + 1].listValue; i += 2
            default: i += 1
            }
        }

        // ENVELOPE (RFC 3501): date subject from sender reply-to to cc bcc
        // in-reply-to message-id
        let env = envelope ?? []
        let subject = env.count > 1 ? MIMEHeader.decode(env[1].stringValue ?? "") : ""
        let fromList = env.count > 2 ? addresses(env[2]) : []
        let toList = env.count > 5 ? addresses(env[5]) : []
        let ccList = env.count > 6 ? addresses(env[6]) : []
        let messageID = env.count > 9 ? env[9].stringValue : nil
        let from = fromList.first
        let date = parseDate(env.first?.stringValue) ?? parseInternalDate(internalDate) ?? Date()

        return MessageSummary(
            uid: uid,
            subject: subject.isEmpty ? "(No Subject)" : subject,
            fromName: from?.name ?? from?.email ?? "",
            fromAddress: from?.email ?? "",
            toDisplay: toList.map { $0.name ?? $0.email }.joined(separator: ", "),
            toAddresses: toList.map(\.email),
            ccAddresses: ccList.map(\.email),
            messageID: messageID,
            date: date,
            isSeen: flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame },
            isFlagged: flags.contains { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame }
        )
    }

    private func addresses(_ token: IMAPToken) -> [(name: String?, email: String)] {
        guard let list = token.listValue else { return [] }
        return list.compactMap { addr in
            guard let parts = addr.listValue, parts.count >= 4 else { return nil }
            let name = parts[0].stringValue.map(MIMEHeader.decode)
            let mailbox = parts[2].stringValue ?? ""
            let host = parts[3].stringValue ?? ""
            let email = host.isEmpty ? mailbox : "\(mailbox)@\(host)"
            return (name, email)
        }
    }

    /// Locate the last `{n}\r\n` literal in a FETCH part and return its bytes.
    private func extractLiteral(from part: Data) -> Data? {
        let bytes = [UInt8](part)
        var i = 0
        var result: Data?
        while i < bytes.count {
            if bytes[i] == 0x7B { // {
                var j = i + 1
                var n = 0
                var hasDigits = false
                while j < bytes.count, bytes[j] >= 0x30, bytes[j] <= 0x39 {
                    n = n * 10 + Int(bytes[j] - 0x30); j += 1; hasDigits = true
                }
                if hasDigits, j < bytes.count, bytes[j] == 0x7D { // }
                    var k = j + 1
                    if k < bytes.count, bytes[k] == 0x0D { k += 1 }
                    if k < bytes.count, bytes[k] == 0x0A { k += 1 }
                    let end = min(k + n, bytes.count)
                    result = Data(bytes[k..<end])
                    i = end
                    continue
                }
            }
            i += 1
        }
        return result
    }

    private func trailingLiteralLength(_ line: Data) -> Int? {
        var bytes = [UInt8](line)
        while bytes.last == 0x0A || bytes.last == 0x0D { bytes.removeLast() }
        guard bytes.last == 0x7D else { return nil } // }
        var idx = bytes.count - 2
        var digits: [UInt8] = []
        while idx >= 0, bytes[idx] >= 0x30, bytes[idx] <= 0x39 {
            digits.insert(bytes[idx], at: 0); idx -= 1
        }
        guard idx >= 0, bytes[idx] == 0x7B, !digits.isEmpty else { return nil } // {
        return Int(String(decoding: digits, as: UTF8.self))
    }

    private func dropPrefix(_ part: Data, after keyword: String) -> Data {
        let str = String(decoding: part, as: UTF8.self)
        if let range = str.range(of: keyword) {
            let rest = str[range.upperBound...]
            return Data(rest.utf8)
        }
        return part
    }

    private func quoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func displayName(for path: String) -> String {
        if path.uppercased() == "INBOX" { return "Inbox" }
        return path.split(whereSeparator: { $0 == "/" }).last.map(String.init) ?? path
    }

    private func firstNumber(in string: String) -> Int? {
        let digits = string.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: Date parsing

    private func parseDate(_ raw: String?) -> Date? {
        guard var str = raw?.trimmingCharacters(in: .whitespaces), !str.isEmpty else { return nil }
        if let paren = str.firstIndex(of: "(") { str = String(str[..<paren]).trimmingCharacters(in: .whitespaces) }
        for format in Self.rfc2822Formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: str) { return date }
        }
        return nil
    }

    private func parseInternalDate(_ raw: String?) -> Date? {
        guard let str = raw else { return nil }
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: str)
    }

    nonisolated private static let rfc2822Formats = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss",
    ]

    // Instance-owned (actor-isolated) so DateFormatter's mutable state is never shared.
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
