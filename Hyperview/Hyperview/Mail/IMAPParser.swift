//
//  IMAPParser.swift
//  Hyperview
//
//  A small recursive-descent tokenizer for IMAP response data (RFC 3501 §4):
//  atoms, quoted strings, NIL, parenthesized lists, and {n} literals. FETCH /
//  ENVELOPE responses are S-expressions, so a token tree is the natural shape to
//  interpret. Also decodes RFC 2047 encoded-words in headers.
//

import Foundation

nonisolated indirect enum IMAPToken: Sendable {
    case atom(String)
    case string(String)
    case nilValue
    case list([IMAPToken])

    /// String value for atoms/strings; nil for NIL/lists.
    var stringValue: String? {
        switch self {
        case .atom(let s), .string(let s): return s
        case .nilValue: return nil
        case .list: return nil
        }
    }

    var intValue: Int? {
        guard let s = stringValue else { return nil }
        return Int(s)
    }

    var listValue: [IMAPToken]? {
        if case .list(let items) = self { return items }
        return nil
    }
}

nonisolated struct IMAPParser {
    private let bytes: [UInt8]
    private var i = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }

    /// Parse the token stream to end. Returns top-level tokens.
    mutating func parseAll() -> [IMAPToken] {
        var out: [IMAPToken] = []
        while true {
            skipSpaces()
            guard i < bytes.count else { break }
            let before = i
            guard let token = parseToken() else { break }
            out.append(token)
            if i == before { break } // safety: never spin if a token can't advance
        }
        return out
    }

    private mutating func parseToken() -> IMAPToken? {
        skipSpaces()
        guard i < bytes.count else { return nil }
        let c = bytes[i]
        switch c {
        case 0x28: // (
            return parseList()
        case 0x22: // "
            return .string(parseQuoted())
        case 0x7B: // {
            return .string(parseLiteral())
        default:
            return parseAtom()
        }
    }

    private mutating func parseList() -> IMAPToken {
        i += 1 // consume (
        var items: [IMAPToken] = []
        while i < bytes.count {
            skipSpaces()
            if i < bytes.count, bytes[i] == 0x29 { i += 1; break } // )
            guard let token = parseToken() else { break }
            items.append(token)
        }
        return .list(items)
    }

    private mutating func parseQuoted() -> String {
        i += 1 // consume opening "
        var out: [UInt8] = []
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x5C, i + 1 < bytes.count { // backslash escape
                out.append(bytes[i + 1]); i += 2; continue
            }
            if c == 0x22 { i += 1; break } // closing "
            out.append(c); i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func parseLiteral() -> String {
        i += 1 // consume {
        var count = 0
        while i < bytes.count, bytes[i] != 0x7D { // }
            if let d = digit(bytes[i]) { count = count * 10 + d }
            i += 1
        }
        i += 1 // consume }
        // consume CRLF
        if i < bytes.count, bytes[i] == 0x0D { i += 1 }
        if i < bytes.count, bytes[i] == 0x0A { i += 1 }
        let end = min(i + count, bytes.count)
        let slice = bytes[i..<end]
        i = end
        return String(decoding: slice, as: UTF8.self)
    }

    private mutating func parseAtom() -> IMAPToken {
        var out: [UInt8] = []
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x20 || c == 0x28 || c == 0x29 || c == 0x0D || c == 0x0A { break }
            out.append(c); i += 1
        }
        let s = String(decoding: out, as: UTF8.self)
        if s.caseInsensitiveCompare("NIL") == .orderedSame { return .nilValue }
        return .atom(s)
    }

    private mutating func skipSpaces() {
        // Skip SP, TAB, CR, LF — response parts carry trailing CRLF, and leaving
        // it unconsumed would stall the caller (parseAtom can't consume CR/LF).
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A { i += 1 } else { break }
        }
    }

    private func digit(_ c: UInt8) -> Int? {
        (c >= 0x30 && c <= 0x39) ? Int(c - 0x30) : nil
    }
}

// MARK: - RFC 2047 encoded-word decoding

nonisolated enum MIMEHeader {
    /// Decode encoded-words like `=?UTF-8?B?...?=` / `=?ISO-8859-1?Q?...?=`.
    static func decode(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        var result = ""
        var remainder = Substring(raw)

        while let start = remainder.range(of: "=?") {
            result += remainder[remainder.startIndex..<start.lowerBound]
            let afterStart = remainder[start.upperBound...]
            guard let end = afterStart.range(of: "?=") else {
                result += remainder[start.lowerBound...]
                remainder = ""
                break
            }
            let word = afterStart[afterStart.startIndex..<end.lowerBound]
            let parts = word.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3, let decoded = decodeWord(charset: String(parts[0]), encoding: String(parts[1]), text: String(parts[2])) {
                result += decoded
            } else {
                result += "=?" + word + "?="
            }
            remainder = afterStart[end.upperBound...]
        }
        result += remainder
        return result
    }

    private static func decodeWord(charset: String, encoding: String, text: String) -> String? {
        let data: Data?
        switch encoding.uppercased() {
        case "B":
            data = Data(base64Encoded: text)
        case "Q":
            data = decodeQ(text)
        default:
            return nil
        }
        guard let data else { return nil }
        let enc = stringEncoding(for: charset)
        return String(data: data, encoding: enc) ?? String(decoding: data, as: UTF8.self)
    }

    private static func decodeQ(_ text: String) -> Data {
        var out = [UInt8]()
        let chars = Array(text.utf8)
        var idx = 0
        while idx < chars.count {
            let c = chars[idx]
            if c == 0x5F { // _ = space
                out.append(0x20); idx += 1
            } else if c == 0x3D, idx + 2 < chars.count,
                      let hi = hex(chars[idx + 1]), let lo = hex(chars[idx + 2]) {
                out.append(UInt8(hi * 16 + lo)); idx += 3
            } else {
                out.append(c); idx += 1
            }
        }
        return Data(out)
    }

    static func stringEncoding(for charset: String) -> String.Encoding {
        switch charset.uppercased() {
        case "UTF-8", "UTF8": return .utf8
        case "ISO-8859-1", "LATIN1": return .isoLatin1
        case "US-ASCII", "ASCII": return .ascii
        case "WINDOWS-1252", "CP1252": return .windowsCP1252
        default: return .utf8
        }
    }

    private static func hex(_ c: UInt8) -> Int? {
        switch c {
        case 0x30...0x39: return Int(c - 0x30)
        case 0x41...0x46: return Int(c - 0x41 + 10)
        case 0x61...0x66: return Int(c - 0x61 + 10)
        default: return nil
        }
    }
}
