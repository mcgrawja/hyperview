//
//  WebDAVClient.swift
//  Unifyr
//
//  A tiny from-scratch WebDAV client — enough to BROWSE a server: list a folder
//  (PROPFIND) and download a file (GET). This is the iOS answer to "my SMB share
//  shows empty": iOS won't let a third-party app enumerate a network share picked
//  through the Files app (Apple's SMB File Provider doesn't back POSIX directory
//  reads), so instead of piggybacking on Files we talk to the server directly.
//
//  Everything here is `nonisolated`: the networking and XML parsing run off the
//  main actor, and the value types cross actors freely. Authentication is HTTP
//  Basic in the `Authorization` header; the session accepts self-signed TLS
//  because a personal NAS almost always uses a self-signed certificate and the
//  user explicitly added the server (see WebDAVSessionDelegate).
//

import Foundation
import UniformTypeIdentifiers

// MARK: - Entry

/// One resource in a WebDAV listing — the remote analogue of `DriveItem`.
nonisolated struct WebDAVEntry: Identifiable, Hashable {
    /// Absolute URL to the resource (href resolved against the listed folder).
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int?
    let modified: Date?
    /// The server-reported MIME type, if any (`getcontenttype`).
    let contentTypeString: String?

    var id: URL { url }

    var contentType: UTType? {
        if let contentTypeString, let type = UTType(mimeType: contentTypeString) { return type }
        let ext = url.pathExtension
        return ext.isEmpty ? nil : UTType(filenameExtension: ext)
    }

    /// Human-readable type, mirroring `DriveItem.kind`.
    var kind: String {
        if isDirectory { return "Folder" }
        if let description = contentType?.localizedDescription { return description }
        return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
    }

    /// SF Symbol for the row — WebDAV listings have no thumbnails until a file is
    /// downloaded, so the type symbol is what a row shows.
    var symbolName: String {
        if isDirectory { return "folder.fill" }
        guard let contentType else { return "doc" }
        if contentType.conforms(to: .image) { return "photo" }
        if contentType.conforms(to: .movie) { return "film" }
        if contentType.conforms(to: .audio) { return "music.note" }
        if contentType.conforms(to: .pdf) { return "doc.richtext" }
        if contentType.conforms(to: .archive) { return "doc.zipper" }
        if contentType.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if contentType.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

// MARK: - Errors

nonisolated enum WebDAVError: LocalizedError {
    case badServerURL
    /// The host name didn't resolve. For a Tailscale MagicDNS server this almost
    /// always means the device is off the tailnet — a distinct layer from auth.
    case cannotResolveHost
    /// The host resolved but nothing answered (server down / refused / timed out).
    case unreachable
    case unauthorized
    case http(Int)
    case notWebDAV

    var errorDescription: String? {
        switch self {
        case .badServerURL:
            return "That server address isn't a valid URL."
        case .cannotResolveHost:
            return "Couldn't find this server. If it's on your Tailscale network, connect to Tailscale first, then try again."
        case .unreachable:
            return "The server didn't respond. Check that it's online and reachable."
        case .unauthorized:
            return "The username or password was rejected by the server."
        case .http(let code):
            return "The server returned an error (HTTP \(code))."
        case .notWebDAV:
            return "That address didn't answer as a WebDAV server. Check the URL and that WebDAV is enabled."
        }
    }
}

// MARK: - Client

nonisolated struct WebDAVClient: Sendable {
    let baseURL: URL
    let username: String
    let password: String

    private var authHeader: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// Connectivity + auth self-test: PROPFIND Depth:0 on the root. A 207 proves
    /// the host resolved (tailnet reachable), TLS validated, and the credentials
    /// were accepted — without parsing a listing. Throws the layer-specific error
    /// (`.cannotResolveHost` / `.unreachable` / `.unauthorized`) on failure.
    func probe() async throws {
        _ = try await propfind(baseURL, depth: "0")
    }

    /// List a folder. `url` defaults to the server root; pass a subfolder's URL
    /// (from a prior listing) to descend. Returns the folder's children — the
    /// folder itself (the "self" entry PROPFIND Depth:1 lists first) is removed.
    func list(_ url: URL? = nil) async throws -> [WebDAVEntry] {
        let target = url ?? baseURL
        let data = try await propfind(target, depth: "1")
        let entries = WebDAVParser.parse(data, relativeTo: target)
        let targetPath = Self.normalize(target.path)
        return entries.filter { Self.normalize($0.url.path) != targetPath }
    }

    /// Download a file to a uniquely-named temp location and return it, so Quick
    /// Look / ShareLink can preview it with the right name and extension.
    func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let temp: URL
        let response: URLResponse
        do {
            (temp, response) = try await Self.session.download(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401, 403: throw WebDAVError.unauthorized
            default: throw WebDAVError.http(http.statusCode)
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("webdav", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let destination = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    // MARK: Mutations

    /// Create a subfolder (MKCOL).
    func makeDirectory(named name: String, in folder: URL) async throws {
        let target = folder.appendingPathComponent(name, isDirectory: true)
        try await send("MKCOL", url: target, expected: [200, 201])
    }

    /// Upload a file's bytes (PUT), overwriting if it already exists.
    func upload(_ data: Data, toFolder folder: URL, as name: String) async throws {
        let target = folder.appendingPathComponent(name)
        try await send("PUT", url: target, expected: [200, 201, 204], body: data)
    }

    /// Delete a file or folder (DELETE). A 404 is treated as success — the goal
    /// state (gone) is already true.
    func delete(_ url: URL) async throws {
        try await send("DELETE", url: url, expected: [200, 204, 404])
    }

    /// Rename in place (MOVE within the same parent).
    func rename(_ url: URL, to newName: String) async throws {
        try await transfer("MOVE", from: url, toName: newName)
    }

    /// Duplicate (COPY within the same parent).
    func duplicate(_ url: URL, to newName: String) async throws {
        try await transfer("COPY", from: url, toName: newName)
    }

    private func transfer(_ method: String, from url: URL, toName newName: String) async throws {
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(newName, isDirectory: url.hasDirectoryPath)
        try await send(method, url: url, expected: [200, 201, 204], headers: [
            "Destination": destination.absoluteString,
            "Overwrite": "F",   // don't clobber an existing name — surfaces as an error
        ])
    }

    /// A one-shot WebDAV verb with no response body to parse. Maps auth and
    /// transport failures the same way PROPFIND does.
    private func send(
        _ method: String, url: URL, expected: Set<Int>,
        headers: [String: String] = [:], body: Data? = nil
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = body

        let response: URLResponse
        do {
            (_, response) = try await Self.session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.notWebDAV }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        guard expected.contains(http.statusCode) else { throw WebDAVError.http(http.statusCode) }
    }

    // MARK: Plumbing

    /// One PROPFIND, with the HTTP status mapped to layer-specific errors so the
    /// UI can distinguish no-tailnet from bad-auth from server-down.
    private func propfind(_ url: URL, depth: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = Self.propfindBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.notWebDAV }
        switch http.statusCode {
        case 207: return data                              // Multi-Status — the WebDAV success
        case 401, 403: throw WebDAVError.unauthorized
        case 200: throw WebDAVError.notWebDAV              // a plain web server, not WebDAV
        default: throw WebDAVError.http(http.statusCode)
        }
    }

    /// Translate URLSession transport failures into the two network-layer states
    /// we surface distinctly. DNS failures on a MagicDNS host mean "off the
    /// tailnet"; a resolved-but-silent host means "server down".
    private static func mapTransportError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return WebDAVError.cannotResolveHost
        case .cannotConnectToHost, .timedOut, .networkConnectionLost:
            return WebDAVError.unreachable
        default:
            return error
        }
    }

    /// Trailing slashes are meaningless for identity here (a collection href ends
    /// in "/", the request path may not), and Foundation reports the root path as
    /// "" while its href is "/". Normalize both to a canonical form before
    /// comparing so the "self" entry filters out even at the root.
    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    private static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <D:propfind xmlns:D="DAV:"><D:prop>\
    <D:displayname/><D:resourcetype/><D:getcontentlength/><D:getlastmodified/><D:getcontenttype/>\
    </D:prop></D:propfind>
    """.utf8)

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": "Unifyr-WebDAV/1"]
        return URLSession(configuration: config, delegate: WebDAVSessionDelegate(), delegateQueue: nil)
    }()
}

// MARK: - TLS

/// TLS policy: validate normally first — so a real public-CA certificate (e.g. a
/// Let's Encrypt cert behind Tailscale's HTTPS termination) gets full MITM
/// protection — and ONLY fall back to accepting the certificate when standard
/// evaluation fails, which is the self-signed personal-NAS case the user opted
/// into by adding the server. The password never passes through here; it rides
/// the Authorization header.
private nonisolated final class WebDAVSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)   // valid chain — let the system handle it
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))  // self-signed fallback
        }
    }
}

// MARK: - PROPFIND parsing

/// Parses a `D:multistatus` PROPFIND response. Namespace processing is on, so it
/// matches local element names and works whatever prefix the server uses (D:, d:,
/// or a default namespace).
private nonisolated final class WebDAVParser: NSObject, XMLParserDelegate {
    private let relativeTo: URL
    private var entries: [WebDAVEntry] = []
    private var buffer = ""

    // Fields of the response currently being read.
    private var href = ""
    private var displayName = ""
    private var isDir = false
    private var length: String?
    private var modified: String?
    private var contentType: String?

    private init(relativeTo: URL) { self.relativeTo = relativeTo }

    static func parse(_ data: Data, relativeTo: URL) -> [WebDAVEntry] {
        let delegate = WebDAVParser(relativeTo: relativeTo)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
        switch elementName {
        case "response":
            href = ""; displayName = ""; isDir = false
            length = nil; modified = nil; contentType = nil
        case "collection":
            isDir = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href": href = text
        case "displayname": displayName = text
        case "getcontentlength": length = text
        case "getlastmodified": modified = text
        case "getcontenttype": contentType = text
        case "response":
            if let entry = makeEntry() { entries.append(entry) }
        default:
            break
        }
        buffer = ""
    }

    private func makeEntry() -> WebDAVEntry? {
        guard !href.isEmpty,
              let url = URL(string: href, relativeTo: relativeTo)?.absoluteURL else { return nil }
        // Derive the name from the href, not displayname: rclone leaves
        // displayname empty at the root, and the href's last component is the
        // reliable source for both files and folders.
        let name: String = {
            let fromHref = url.lastPathComponent
            if !fromHref.isEmpty, fromHref != "/" { return fromHref }
            if !displayName.isEmpty { return displayName }
            return url.host ?? "/"
        }()
        return WebDAVEntry(
            url: url,
            name: name,
            isDirectory: isDir,
            size: length.flatMap { Int($0) },
            modified: modified.flatMap(Self.parseHTTPDate),
            contentTypeString: contentType?.isEmpty == false ? contentType : nil
        )
    }

    /// `getlastmodified` is an RFC 1123 date ("Mon, 12 Jan 2026 12:00:00 GMT").
    private static func parseHTTPDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}
