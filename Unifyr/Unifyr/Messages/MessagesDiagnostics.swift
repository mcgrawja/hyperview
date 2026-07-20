#if os(macOS)
//
//  MessagesDiagnostics.swift
//  Unifyr
//
//  Launch-time access check for the Messages module. Writes a single
//  CONTENT-FREE status line (access yes/no + row counts, never message text)
//  to the sandbox container home so Full Disk Access health is verifiable
//  from a terminal without FDA:
//    ~/Library/Containers/com.mcgraw.Hyperview/Data/messages-debug.log
//

import Foundation
import SQLite3

nonisolated enum MessagesDiagnostics {
    static func run() {
        Task.detached(priority: .utility) {
            var line = "\(Date()) — "
            defer {
                try? (line + "\n").write(
                    toFile: NSHomeDirectory() + "/messages-debug.log",
                    atomically: true,
                    encoding: .utf8
                )
            }

            var db: OpaquePointer?
            let rc = sqlite3_open_v2(MessagesDatabase.chatDBPath, &db, SQLITE_OPEN_READONLY, nil)
            defer { sqlite3_close(db) }
            guard rc == SQLITE_OK, let db else {
                line += "NO ACCESS (open rc \(rc))"
                return
            }
            sqlite3_busy_timeout(db, 1500)
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM chat", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else {
                line += "NO ACCESS (query failed)"
                return
            }
            line += "OK — \(sqlite3_column_int64(statement, 0)) chats visible"

            // Automation probe: a harmless `get name` proves the sandbox
            // exception + TCC grant end-to-end (triggers the consent prompt
            // on first run). NSAppleScript is main-thread-only.
            let automation = await MainActor.run { () -> String in
                guard let script = NSAppleScript(source: "tell application \"Messages\" to get name") else {
                    return "script compile failed"
                }
                var errorInfo: NSDictionary?
                script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown"
                    return "FAILED (\(number): \(message))"
                }
                return "OK"
            }
            line += " | automation: \(automation)"
        }
    }
}

#endif
