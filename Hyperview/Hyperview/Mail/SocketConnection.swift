//
//  SocketConnection.swift
//  Hyperview
//
//  Async TLS/TCP socket over Network.framework (D9: no third-party SDKs), shared
//  by the IMAP and SMTP clients. An actor owns one NWConnection and an internal
//  read buffer, exposing line- and byte-oriented reads plus STARTTLS upgrade.
//

import Foundation
import Network

actor SocketConnection {
    private var connection: NWConnection
    private let host: String
    private let port: Int
    private var buffer = Data()
    private let queue = DispatchQueue(label: "com.mcgraw.Hyperview.socket")

    private static let crlf = Data([0x0D, 0x0A])

    /// One-shot resume guard for callbacks delivered on the serial `queue`.
    private final class Once: @unchecked Sendable {
        var done = false
        func fire(_ body: () -> Void) { if !done { done = true; body() } }
    }

    init(host: String, port: Int, useTLS: Bool) {
        self.host = host
        self.port = port
        let params = useTLS ? NWParameters(tls: NWProtocolTLS.Options()) : NWParameters.tcp
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 993,
            using: params
        )
    }

    func start() async throws {
        try await startConnection(connection)
    }

    /// Upgrade a plaintext connection to TLS (SMTP STARTTLS). Reconnecting with a
    /// fresh TLS-enabled NWConnection is simplest and reliable for our flows.
    func upgradeToTLS() async throws {
        connection.cancel()
        buffer.removeAll()
        let params = NWParameters(tls: NWProtocolTLS.Options())
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 587,
            using: params
        )
        try await startConnection(connection)
    }

    /// Seconds to wait for the connection to come up before giving up. Without
    /// this the app hangs forever on an unreachable host — see `.waiting` below.
    private static let connectTimeout: TimeInterval = 20

    private func startConnection(_ conn: NWConnection) async throws {
        let once = Once()
        // Locals: the callbacks run on `queue`, outside this actor.
        let host = self.host
        let port = self.port
        let queue = self.queue

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // DispatchWorkItem isn't Sendable, but the deadline and the state
            // handler both run on the same serial `queue` and `Once` guards the
            // resume — same pattern as receiveMore's read timeout.
            nonisolated(unsafe) let deadline = DispatchWorkItem {
                once.fire {
                    MailLog.log("[Mail] connect to \(host):\(port) gave up after \(Int(Self.connectTimeout))s")
                    conn.cancel()
                    cont.resume(throwing: MailError.timeout)
                }
            }
            queue.asyncAfter(deadline: .now() + Self.connectTimeout, execute: deadline)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    deadline.cancel()
                    once.fire { cont.resume() }
                case .failed(let error):
                    deadline.cancel()
                    once.fire { cont.resume(throwing: error) }
                case .cancelled:
                    deadline.cancel()
                    once.fire { cont.resume(throwing: MailError.connectionClosed) }
                case .waiting(let error):
                    // NWConnection does NOT fail on an unreachable host — a bad
                    // DNS name or a dead route parks it here and it retries
                    // forever. Left unhandled, the UI just says "Connecting…"
                    // with nothing to report. Log the reason; the deadline above
                    // turns it into a real error.
                    MailLog.log("[Mail] connect to \(host):\(port) waiting — \(error)")
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        conn.stateUpdateHandler = nil
    }

    func send(_ string: String) async throws {
        try await send(Data(string.utf8))
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Read one CRLF-terminated line (terminator included).
    func readLine() async throws -> Data {
        while true {
            if let range = buffer.firstRange(of: Self.crlf) {
                let line = buffer.subdata(in: buffer.startIndex..<range.upperBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            try await receiveMore()
        }
    }

    /// Read exactly `n` bytes (for IMAP literals).
    func readExact(_ n: Int) async throws -> Data {
        while buffer.count < n {
            try await receiveMore()
        }
        let out = Data(buffer.prefix(n))
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + n))
        return out
    }

    func close() {
        connection.cancel()
    }

    /// Seconds to wait for any single read before failing with `.timeout`.
    private let readTimeout: TimeInterval = 30

    private func receiveMore() async throws {
        let conn = connection
        let queue = queue
        let timeout = readTimeout
        let chunk: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once()
            // Timer and receive callback both run on the serial `queue`, so the
            // Once guard needs no additional synchronization.
            // DispatchWorkItem isn't Sendable, but timer + receive callback both
            // run on the same serial `queue` and `Once` guards the resume.
            nonisolated(unsafe) let timer = DispatchWorkItem {
                once.fire { cont.resume(throwing: MailError.timeout) }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                timer.cancel()
                once.fire {
                    if let error { cont.resume(throwing: error); return }
                    if let data, !data.isEmpty { cont.resume(returning: data); return }
                    if isComplete { cont.resume(throwing: MailError.connectionClosed); return }
                    cont.resume(returning: Data())
                }
            }
        }
        buffer.append(chunk)
    }
}
