//
//  MessagesDiagnostics.swift
//  Hyperview
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
        }
    }
}
