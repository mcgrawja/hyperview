//
//  MCPHTTPServer.swift
//  Hyperview
//
//  Minimal HTTP/1.1 server bound to 127.0.0.1 only — the local shim between
//  the app's tool executor and the Node stdio bridge that Claude Desktop
//  launches (§7.2). Token-gated: every request must carry X-Hyperview-Token.
//
//    GET  /health -> {"ok":true}
//    GET  /tools  -> {"tools":[...]}            (MCP tools/list shape)
//    POST /call   -> {"name":..., "arguments":{}} -> {"ok":bool, "content"/"error"}
//

import Foundation
import Network

actor MCPHTTPServer {
    private var listener: NWListener?
    let port: UInt16
    private let token: String
    private let route: @Sendable (_ method: String, _ path: String, _ body: Data) async -> Data

    init(
        port: UInt16,
        token: String,
        route: @escaping @Sendable (_ method: String, _ path: String, _ body: Data) async -> Data
    ) {
        self.port = port
        self.token = token
        self.route = route
    }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? 48219
        )
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { connection in
            Task { [weak self] in
                await self?.handle(connection)
            }
        }
        listener.start(queue: DispatchQueue(label: "com.mcgraw.Hyperview.mcp"))
        self.listener = listener
        MailLog.log("[MCP] HTTP shim listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        MailLog.log("[MCP] HTTP shim stopped")
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) async {
        nonisolated(unsafe) let conn = connection
        conn.start(queue: DispatchQueue(label: "com.mcgraw.Hyperview.mcp.conn"))

        var buffer = Data()
        while buffer.count < 4_000_000 {
            guard let chunk = await receive(conn) else { break }
            buffer.append(chunk)
            guard let request = Self.parse(buffer) else { continue }

            let responseBody: Data
            let status: String
            if request.headers["x-hyperview-token"] != token {
                status = "401 Unauthorized"
                responseBody = Data(#"{"ok":false,"error":"unauthorized"}"#.utf8)
            } else {
                status = "200 OK"
                responseBody = await route(request.method, request.path, request.body)
            }
            let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
            await send(conn, Data(head.utf8) + responseBody)
            break
        }
        conn.cancel()
    }

    private func receive(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if error != nil || (isComplete && data == nil) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func send(_ conn: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    // MARK: - Request parsing

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    /// Returns a complete request once headers + full body have arrived.
    private static func parse(_ raw: Data) -> Request? {
        guard let headerEnd = raw.firstRange(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return nil }
        let headerData = raw.subdata(in: raw.startIndex..<headerEnd.lowerBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let body = raw.subdata(in: headerEnd.upperBound..<raw.endIndex)
        guard body.count >= contentLength else { return nil } // wait for more
        return Request(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: body.prefix(contentLength)
        )
    }
}
