//
//  SMTPStreamSession.swift
//  Unifyr
//
//  SMTP transport over Foundation streams. Unlike NWConnection, CFStream can
//  upgrade an established plaintext connection to TLS in place — required for
//  STARTTLS on port 587 (iCloud, Gmail). Runs synchronously on a dedicated
//  run-loop thread; SMTPClient bridges it to async.
//
//  Not Sendable — created and used entirely within one thread.
//

import Foundation

/// `nonisolated` is essential: this runs on a dedicated background thread, not
/// the (default) main actor. Without it, Swift's isolation checks trap on the
/// first stream access from that thread.
nonisolated final class SMTPStreamSession {
    private var input: InputStream!
    private var output: OutputStream!
    private let host: String
    private let port: Int
    private let timeout: TimeInterval = 30

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    // MARK: Lifecycle

    func open(implicitTLS: Bool) throws {
        var i: InputStream?
        var o: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &i, outputStream: &o)
        guard let i, let o else { throw MailError.notConnected }
        input = i
        output = o
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        if implicitTLS { enableTLS() }
        input.open()
        output.open()
        try waitOpen()
    }

    /// In-place STARTTLS upgrade (after a 220 response to STARTTLS).
    func startTLS() { enableTLS() }

    func close() {
        input?.close()
        output?.close()
    }

    // MARK: Commands

    func command(_ line: String, expect code: Int) throws {
        MailLog.log("[SMTP] > \(line.split(separator: " ").first.map(String.init) ?? "?")")
        try writeRaw(line + "\r\n")
        try expect(code)
    }

    /// Like `command`, but never logs the content (for base64 credentials).
    func commandSecret(_ line: String, expect code: Int) throws {
        MailLog.log("[SMTP] > ***")
        try writeRaw(line + "\r\n")
        try expect(code)
    }

    func sendBody(_ payload: String) throws {
        MailLog.log("[SMTP] > <message: \(payload.utf8.count) bytes>")
        try writeRaw(payload)
        try expect(250)
    }

    func expect(_ code: Int) throws {
        let (got, text) = try readReply()
        MailLog.log("[SMTP] < \(got) \(text.prefix(80))")
        guard got == code else {
            if got == 535 { throw MailError.authenticationFailed }
            throw MailError.commandFailed("SMTP \(got): \(text)")
        }
    }

    // MARK: - I/O (run-loop pumped)

    private func enableTLS() {
        let key = Stream.PropertyKey.socketSecurityLevelKey
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: key)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: key)
    }

    private func pump() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }

    private func waitOpen() throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if input.streamStatus == .error || output.streamStatus == .error {
                throw MailError.connectionClosed
            }
            if input.streamStatus.rawValue >= Stream.Status.open.rawValue,
               output.streamStatus.rawValue >= Stream.Status.open.rawValue {
                return
            }
            if Date() > deadline { throw MailError.timeout }
            pump()
        }
    }

    private func writeRaw(_ string: String) throws {
        let bytes = [UInt8](string.utf8)
        var offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        while offset < bytes.count {
            if output.hasSpaceAvailable {
                let n = bytes.withUnsafeBufferPointer { ptr in
                    output.write(ptr.baseAddress!.advanced(by: offset), maxLength: bytes.count - offset)
                }
                if n <= 0 { throw MailError.connectionClosed }
                offset += n
            } else {
                if output.streamStatus == .error { throw MailError.connectionClosed }
                if Date() > deadline { throw MailError.timeout }
                pump()
            }
        }
    }

    private func readReply() throws -> (Int, String) {
        var lines: [String] = []
        var code = 0
        while true {
            let line = try readLine().trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            lines.append(line)
            guard line.count >= 3, let parsed = Int(line.prefix(3)) else { continue }
            code = parsed
            let fourth = line.index(line.startIndex, offsetBy: 3)
            let isFinal = line.count == 3 || line[fourth] == " "
            if isFinal { break }
        }
        return (code, lines.joined(separator: " "))
    }

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        var byte = [UInt8](repeating: 0, count: 1)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if input.hasBytesAvailable {
                let n = input.read(&byte, maxLength: 1)
                if n <= 0 { break }
                bytes.append(byte[0])
                if byte[0] == 0x0A { break }
            } else {
                if input.streamStatus == .atEnd { break }
                if input.streamStatus == .error { throw MailError.connectionClosed }
                if Date() > deadline { throw MailError.timeout }
                pump()
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
