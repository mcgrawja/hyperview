//
//  MessagesSender.swift
//  Hyperview
//
//  Sending half of the Messages wrapper: there is no public send API, so this
//  automates Messages.app with Apple events (NSAppleScript — main thread
//  only). Needs the com.apple.security.automation.apple-events entitlement;
//  the first send triggers the TCC "Hyperview wants to control Messages"
//  prompt. Primary path targets the existing conversation by its chat guid
//  (works for groups and 1:1); fallback addresses the participant directly.
//

import Foundation

@MainActor
enum MessagesSender {
    enum SendError: LocalizedError {
        case scriptFailure(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailure(let message): return message
            }
        }
    }

    /// Send `text` into the conversation `chatGUID` (e.g.
    /// "iMessage;-;+15551234567"). `fallbackHandle` (1:1 chats) retries by
    /// addressing the participant when the chat-id route fails.
    static func send(_ text: String, chatGUID: String, fallbackHandle: String?, service: String) throws {
        let textExpression = asStringExpression(text)
        let byChat = """
        tell application "Messages"
            send \(textExpression) to chat id "\(escaped(chatGUID))"
        end tell
        """
        if run(byChat) == nil { return }

        guard let fallbackHandle, !fallbackHandle.isEmpty else {
            throw SendError.scriptFailure("Messages couldn't send to this conversation.")
        }
        let serviceType = service.caseInsensitiveCompare("SMS") == .orderedSame ? "SMS" : "iMessage"
        let byParticipant = """
        tell application "Messages"
            set targetAccount to 1st account whose service type = \(serviceType)
            send \(textExpression) to participant "\(escaped(fallbackHandle))" of targetAccount
        end tell
        """
        if let failure = run(byParticipant) {
            throw SendError.scriptFailure(failure)
        }
    }

    /// Send a file into a conversation (Messages reads the file itself, so
    /// pick files the user chose via an open panel).
    static func sendFile(_ path: String, chatGUID: String, fallbackHandle: String?, service: String) throws {
        let fileExpression = "POSIX file \"\(escaped(path))\""
        let byChat = """
        tell application "Messages"
            send \(fileExpression) to chat id "\(escaped(chatGUID))"
        end tell
        """
        if run(byChat) == nil { return }
        guard let fallbackHandle, !fallbackHandle.isEmpty else {
            throw SendError.scriptFailure("Messages couldn't send the file to this conversation.")
        }
        let serviceType = service.caseInsensitiveCompare("SMS") == .orderedSame ? "SMS" : "iMessage"
        let byParticipant = """
        tell application "Messages"
            set targetAccount to 1st account whose service type = \(serviceType)
            send \(fileExpression) to participant "\(escaped(fallbackHandle))" of targetAccount
        end tell
        """
        if let failure = run(byParticipant) {
            throw SendError.scriptFailure(failure)
        }
    }

    /// Start (or continue) a conversation with a raw handle — used by the
    /// New Message flow, where no chat guid exists yet.
    static func send(_ text: String, toHandle handle: String, service: String = "iMessage") throws {
        let serviceType = service.caseInsensitiveCompare("SMS") == .orderedSame ? "SMS" : "iMessage"
        let script = """
        tell application "Messages"
            set targetAccount to 1st account whose service type = \(serviceType)
            send \(asStringExpression(text)) to participant "\(escaped(handle))" of targetAccount
        end tell
        """
        if let failure = run(script) {
            throw SendError.scriptFailure(failure)
        }
    }

    /// Runs a script; nil on success, error message on failure.
    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            return "Couldn't compile the send script."
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        if let number = errorInfo[NSAppleScript.errorNumber] as? Int, number == -1743 {
            return "Automation permission denied — allow Hyperview to control Messages in System Settings → Privacy & Security → Automation."
        }
        return (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Messages rejected the send."
    }

    /// AppleScript string literals can't contain raw newlines — build a
    /// `"line" & linefeed & "line"` expression instead.
    private static func asStringExpression(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { "\"\(escaped($0))\"" }
        return lines.joined(separator: " & linefeed & ")
    }

    private static func escaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
