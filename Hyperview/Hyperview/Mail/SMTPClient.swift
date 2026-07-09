//
//  SMTPClient.swift
//  Hyperview
//
//  A from-scratch SMTP sender (RFC 5321/5322). Message rendering happens on the
//  actor; the wire conversation runs on a dedicated run-loop thread via
//  SMTPStreamSession (STARTTLS on 587, implicit TLS on 465) so it can upgrade
//  the socket in place. Sending is gated behind an in-app confirm (§7).
//

import Foundation

actor SMTPClient {
    private let config: MailServerConfig

    init(config: MailServerConfig) {
        self.config = config
    }

    /// Sends the message; returns the rendered RFC 5322 source so the caller
    /// can APPEND it to the account's Sent mailbox (iCloud and most providers
    /// do NOT save SMTP sends server-side; Gmail does).
    @discardableResult
    func send(_ message: OutgoingMessage, password: String) async throws -> String {
        // Everything the wire thread needs, precomputed as Sendable values so the
        // thread closure never touches the actor.
        let host = config.host
        let port = config.port
        let useImplicitTLS = (port == 465)
        let ehloDomain = config.username.split(separator: "@").last.map(String.init) ?? "localhost"
        let authUser = base64(config.username)
        let authPass = base64(password)
        let from = message.fromAddress
        let recipients = message.to + message.cc
        let rendered = render(message)
        let payload = dotStuff(rendered) + "\r\n.\r\n"

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // (thread body below sends `payload`; the un-stuffed `rendered` is returned)
            let thread = Thread {
                let session = SMTPStreamSession(host: host, port: port)
                do {
                    try session.open(implicitTLS: useImplicitTLS)
                    try session.expect(220)
                    try session.command("EHLO \(ehloDomain)", expect: 250)
                    if !useImplicitTLS {
                        try session.command("STARTTLS", expect: 220)
                        session.startTLS()
                        try session.command("EHLO \(ehloDomain)", expect: 250)
                    }
                    try session.command("AUTH LOGIN", expect: 334)
                    try session.commandSecret(authUser, expect: 334)
                    try session.commandSecret(authPass, expect: 235)
                    try session.command("MAIL FROM:<\(from)>", expect: 250)
                    for recipient in recipients {
                        try session.command("RCPT TO:<\(recipient)>", expect: 250)
                    }
                    try session.command("DATA", expect: 354)
                    try session.sendBody(payload)
                    try? session.command("QUIT", expect: 221)
                    session.close()
                    cont.resume()
                } catch {
                    session.close()
                    cont.resume(throwing: error)
                }
            }
            thread.name = "com.mcgraw.Hyperview.smtp"
            thread.stackSize = 512 * 1024
            thread.start()
        }
        return rendered
    }

    // MARK: - Message rendering (RFC 5322)

    private func render(_ message: OutgoingMessage) -> String {
        var headers: [String] = []
        let fromDisplay = message.fromName.isEmpty
            ? message.fromAddress
            : "\(encodeHeader(message.fromName)) <\(message.fromAddress)>"
        headers.append("From: \(fromDisplay)")
        headers.append("To: \(message.to.joined(separator: ", "))")
        if !message.cc.isEmpty { headers.append("Cc: \(message.cc.joined(separator: ", "))") }
        headers.append("Subject: \(encodeHeader(message.subject))")
        headers.append("Date: \(dateHeader())")
        headers.append("Message-ID: \(messageID())")
        if let inReplyTo = message.inReplyTo, !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(inReplyTo)")
            headers.append("References: \(inReplyTo)")
        }
        headers.append("MIME-Version: 1.0")

        let body = normalizeNewlines(message.body)

        if message.attachments.isEmpty {
            headers.append("Content-Type: text/plain; charset=utf-8")
            headers.append("Content-Transfer-Encoding: 8bit")
            return headers.joined(separator: "\r\n") + "\r\n\r\n" + body
        }

        // multipart/mixed: text part + base64 attachment parts.
        let boundary = "hyperview-\(UUID().uuidString)"
        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")

        var parts: [String] = []
        parts.append("""
        --\(boundary)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        \(body)
        """)
        for attachment in message.attachments {
            let filename = attachment.filename.replacingOccurrences(of: "\"", with: "'")
            let encoded = attachment.data.base64EncodedString(
                options: [.lineLength76Characters, .endLineWithCarriageReturn]
            )
            parts.append("""
            --\(boundary)\r
            Content-Type: \(attachment.mimeType); name="\(filename)"\r
            Content-Disposition: attachment; filename="\(filename)"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(encoded)
            """)
        }
        parts.append("--\(boundary)--")

        return headers.joined(separator: "\r\n") + "\r\n\r\n" + parts.joined(separator: "\r\n")
    }

    private func encodeHeader(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) { return value }
        return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }

    private func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    private func dotStuff(_ text: String) -> String {
        text.components(separatedBy: "\r\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
    }

    private func dateHeader() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: Date())
    }

    private func messageID() -> String {
        let domain = config.username.split(separator: "@").last.map(String.init) ?? "hyperview.local"
        return "<\(UUID().uuidString)@\(domain)>"
    }

    private func base64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }
}
