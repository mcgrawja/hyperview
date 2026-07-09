//
//  MCPController.swift
//  Hyperview
//
//  Owns the MCP surface: the tool executor, the localhost HTTP shim, the
//  shared-secret token, and the audit log (§7: log every MCP tool invocation).
//  Created at app launch; the server starts automatically when enabled.
//

import Foundation
import SwiftData
import Observation

/// One audited tool invocation (§7 safety defaults).
@Model
final class MCPAuditEntry {
    var id: UUID = UUID()
    var date: Date = Date()
    var tool: String = ""
    var detail: String = ""
    var succeeded: Bool = true

    init(tool: String, detail: String, succeeded: Bool) {
        self.id = UUID()
        self.date = Date()
        self.tool = tool
        self.detail = detail
        self.succeeded = succeeded
    }
}

/// Local, non-CloudKit store for automation metadata (audit log).
enum AutomationStore {
    static let schema = Schema([MCPAuditEntry.self])

    @MainActor
    static func makeContainer() -> ModelContainer {
        let configuration = ModelConfiguration(
            "Automation",
            schema: schema,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create Automation container: \(error)")
        }
    }
}

@MainActor
@Observable
final class MCPController {
    enum Status: Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    var status: Status = .stopped

    /// Persisted on/off switch — the server auto-starts on launch when true.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "mcp.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "mcp.enabled")
            Task { newValue ? await self.start() : await self.stop() }
        }
    }

    let port: UInt16 = 48219
    let token: String

    @ObservationIgnored private var server: MCPHTTPServer?
    /// Shared with the in-app Claude chat (Phase 5) — same tools, same audit.
    @ObservationIgnored private(set) var executor: MCPToolExecutor?
    @ObservationIgnored private let automationContainer: ModelContainer

    init(brokers: Brokers, notesContainer: ModelContainer, mailContainer: ModelContainer,
         mailService: MailService, automationContainer: ModelContainer) {
        self.automationContainer = automationContainer

        // Stable shared secret for the localhost shim (generated once).
        if let existing = UserDefaults.standard.string(forKey: "mcp.token") {
            token = existing
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: "mcp.token")
            token = fresh
        }

        let auditContext = automationContainer.mainContext
        executor = MCPToolExecutor(
            brokers: brokers,
            notesContainer: notesContainer,
            mailContainer: mailContainer,
            mailService: mailService
        ) { tool, detail, ok in
            auditContext.insert(MCPAuditEntry(tool: tool, detail: detail, succeeded: ok))
            try? auditContext.save()
        }

        if isEnabled {
            Task { await start() }
        }
    }

    func start() async {
        guard case .running = status else {
            guard let executor else { return }
            let server = MCPHTTPServer(port: port, token: token) { method, path, body in
                await Self.route(method: method, path: path, body: body, executor: executor)
            }
            do {
                try await server.start()
                self.server = server
                status = .running(port: port)
            } catch {
                status = .failed("Couldn't start on port \(port): \(error.localizedDescription)")
            }
            return
        }
    }

    func stop() async {
        await server?.stop()
        server = nil
        status = .stopped
    }

    /// The exact claude_desktop_config.json snippet for this machine.
    var claudeDesktopConfig: String {
        let bridge = MCPController.bridgePath
        return """
        {
          "mcpServers": {
            "hyperview": {
              "command": "node",
              "args": ["\(bridge)"],
              "env": {
                "HYPERVIEW_PORT": "\(port)",
                "HYPERVIEW_TOKEN": "\(token)"
              }
            }
          }
        }
        """
    }

    nonisolated static let bridgePath = "/Users/mcgrawja/Projects/hyperview/mcp-bridge/index.js"

    // MARK: - Routing

    private static func route(method: String, path: String, body: Data, executor: MCPToolExecutor) async -> Data {
        switch (method, path) {
        case ("GET", "/health"):
            return Data(#"{"ok":true,"app":"Hyperview"}"#.utf8)
        case ("GET", "/tools"):
            return MCPToolRegistry.listJSON()
        case ("POST", "/call"):
            // Body Data crosses the actor hop (Sendable); parsing happens on
            // the main actor inside the executor.
            let result = await executor.execute(callBody: body)
            let response: [String: Any] = result.ok
                ? ["ok": true, "content": result.content]
                : ["ok": false, "error": result.content]
            return (try? JSONSerialization.data(withJSONObject: response)) ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
        default:
            return Data(#"{"ok":false,"error":"not found"}"#.utf8)
        }
    }
}
