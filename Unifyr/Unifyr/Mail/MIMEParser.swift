//
//  MIMEParser.swift
//  Unifyr
//
//  A pragmatic RFC 2045/2046 message parser: enough to extract a readable
//  text/plain and/or text/html body from the common cases (single-part and
//  multipart/alternative|mixed, base64 / quoted-printable, UTF-8 & Latin-1).
//  Exotic nesting degrades gracefully rather than crashing.
//

import Foundation

nonisolated enum MIMEParser {

    static func parse(_ raw: Data) -> MessageBody {
        let entity = Entity(raw)
        MailLog.log("[MIME] top content-type=\(entity.contentType) boundary=\(entity.boundary ?? "nil") bodyBytes=\(entity.body.count)")
        var text: String?
        var html: String?
        var attachments: [AttachmentPart] = []
        collect(entity, text: &text, html: &html, attachments: &attachments)
        MailLog.log("[MIME] result textLen=\(text?.count ?? -1) htmlLen=\(html?.count ?? -1) attachments=\(attachments.count)")
        return MessageBody(text: text, html: html, attachments: attachments)
    }

    // MARK: - Entity

    private struct Entity {
        var headers: [String: String]
        var body: Data

        init(_ raw: Data) {
            let (headerData, bodyData) = Self.splitHeaders(raw)
            self.headers = Self.parseHeaders(headerData)
            self.body = bodyData
        }

        init(headers: [String: String], body: Data) {
            self.headers = headers
            self.body = body
        }

        var contentType: String {
            (headers["content-type"] ?? "text/plain").lowercased()
        }
        var transferEncoding: String {
            (headers["content-transfer-encoding"] ?? "7bit").lowercased().trimmingCharacters(in: .whitespaces)
        }
        var boundary: String? {
            guard let ct = headers["content-type"],
                  let range = ct.range(of: "boundary=", options: .caseInsensitive) else { return nil }
            var value = String(ct[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            return value.isEmpty ? nil : value
        }
        var charset: String {
            parameter("charset", in: headers["content-type"]) ?? "utf-8"
        }

        /// Explicit attachment disposition, a declared filename, or a non-text,
        /// non-multipart type (image/pdf/zip/…).
        var isAttachment: Bool {
            let disposition = (headers["content-disposition"] ?? "").lowercased()
            if disposition.contains("attachment") { return true }
            if filename != nil { return true }
            let type = contentType
            return !type.hasPrefix("text/") && !type.hasPrefix("multipart/") && !type.hasPrefix("message/")
        }

        /// Content-Disposition `filename=` or Content-Type `name=`, RFC 2047
        /// decoded.
        var filename: String? {
            let raw = parameter("filename", in: headers["content-disposition"])
                ?? parameter("name", in: headers["content-type"])
            return raw.map(MIMEHeader.decode)
        }

        /// Content-ID with the surrounding <> stripped (for cid: references).
        var contentID: String? {
            guard let raw = headers["content-id"]?.trimmingCharacters(in: .whitespaces) else { return nil }
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }

        private func parameter(_ name: String, in header: String?) -> String? {
            guard let header,
                  let range = header.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
            var value = String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                value.removeFirst()
                if let end = value.firstIndex(of: "\"") { value = String(value[..<end]) }
            } else if let semi = value.firstIndex(of: ";") {
                value = String(value[..<semi])
            }
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func splitHeaders(_ raw: Data) -> (Data, Data) {
            if let r = raw.firstRange(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                return (raw.subdata(in: raw.startIndex..<r.lowerBound), raw.subdata(in: r.upperBound..<raw.endIndex))
            }
            if let r = raw.firstRange(of: Data([0x0A, 0x0A])) {
                return (raw.subdata(in: raw.startIndex..<r.lowerBound), raw.subdata(in: r.upperBound..<raw.endIndex))
            }
            return (raw, Data())
        }

        private static func parseHeaders(_ data: Data) -> [String: String] {
            // CRITICAL: normalize CRLF -> LF BEFORE splitting. In Swift, "\r\n"
            // is a single grapheme (one Character), so splitting on the "\n"
            // Character never splits CRLF-terminated lines — every header glues
            // into one line and only the first key survives.
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n")
            var headers: [String: String] = [:]
            var currentKey: String?
            var currentValue = ""
            func commit() {
                if let key = currentKey {
                    headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
                }
            }
            for raw in text.components(separatedBy: "\n") {
                if raw.first == " " || raw.first == "\t" { // folded continuation
                    currentValue += " " + raw.trimmingCharacters(in: .whitespaces)
                } else if let colon = raw.firstIndex(of: ":") {
                    commit()
                    currentKey = String(raw[..<colon])
                    currentValue = String(raw[raw.index(after: colon)...])
                }
            }
            commit()
            return headers
        }
    }

    // MARK: - Recursion

    private static func collect(
        _ entity: Entity,
        text: inout String?,
        html: inout String?,
        attachments: inout [AttachmentPart]
    ) {
        let type = entity.contentType
        if type.hasPrefix("multipart/"), let boundary = entity.boundary {
            let parts = splitParts(entity.body, boundary: boundary)
            MailLog.log("[MIME] multipart \(type) -> \(parts.count) parts")
            for part in parts {
                collect(part, text: &text, html: &html, attachments: &attachments)
            }
            return
        }
        MailLog.log("[MIME] leaf \(type) cte=\(entity.transferEncoding) bytes=\(entity.body.count)")

        // Attachment: an explicit disposition, a filename, or any non-text leaf
        // (images, PDFs, …). Inline images carry a Content-ID for cid: refs.
        if entity.isAttachment {
            let data = decodeBodyData(entity)
            guard !data.isEmpty else { return }
            attachments.append(AttachmentPart(
                filename: entity.filename ?? "attachment",
                mimeType: type.components(separatedBy: ";").first ?? "application/octet-stream",
                contentID: entity.contentID,
                data: data
            ))
            return
        }

        let decoded = decodeBody(entity)
        if type.hasPrefix("text/html") {
            if html == nil { html = decoded }
        } else if type.hasPrefix("text/plain") || type.hasPrefix("text/") {
            if text == nil { text = decoded }
        }
    }

    private static func splitParts(_ body: Data, boundary: String) -> [Entity] {
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Entity] = []
        var ranges: [Range<Data.Index>] = []
        var searchStart = body.startIndex
        while let r = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            ranges.append(r)
            searchStart = r.upperBound
        }
        for idx in 0..<ranges.count {
            let start = ranges[idx].upperBound
            let end = (idx + 1 < ranges.count) ? ranges[idx + 1].lowerBound : body.endIndex
            guard start < end else { continue }
            var chunk = body.subdata(in: start..<end)
            // Trim leading CRLF and a trailing CRLF before the next boundary.
            chunk = trimBoundaryWhitespace(chunk)
            if chunk.isEmpty { continue }
            parts.append(Entity(chunk))
        }
        return parts
    }

    private static func trimBoundaryWhitespace(_ data: Data) -> Data {
        var d = data
        // Leading "\r\n" or "--" (closing marker) or "\n"
        if d.first == 0x2D { return Data() } // "--" closing boundary → empty
        while d.first == 0x0D || d.first == 0x0A { d.removeFirst() }
        while d.last == 0x0D || d.last == 0x0A { d.removeLast() }
        return d
    }

    /// Transfer-decoded raw bytes (attachments need Data, not String).
    private static func decodeBodyData(_ entity: Entity) -> Data {
        switch entity.transferEncoding {
        case "base64":
            return Data(base64Encoded: entity.body, options: .ignoreUnknownCharacters) ?? entity.body
        case "quoted-printable":
            return decodeQuotedPrintable(entity.body)
        default:
            return entity.body
        }
    }

    private static func decodeBody(_ entity: Entity) -> String {
        let raw = decodeBodyData(entity)
        let encoding = MIMEHeader.stringEncoding(for: entity.charset)
        return String(data: raw, encoding: encoding) ?? String(decoding: raw, as: UTF8.self)
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x3D { // =
                if i + 1 < bytes.count, bytes[i + 1] == 0x0D, i + 2 < bytes.count, bytes[i + 2] == 0x0A {
                    i += 3; continue // soft line break =\r\n
                }
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    i += 2; continue // soft line break =\n
                }
                if i + 1 == bytes.count {
                    i += 1; continue // trailing soft break whose CRLF was trimmed with the boundary
                }
                if i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                    out.append(UInt8(hi * 16 + lo)); i += 3; continue
                }
            }
            out.append(c); i += 1
        }
        return Data(out)
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
