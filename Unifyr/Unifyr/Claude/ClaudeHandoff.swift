//
//  ClaudeHandoff.swift
//  Unifyr
//
//  One-click handoff to Claude: builds a task prompt that references the
//  Unifyr MCP tools, copies it to the clipboard, and opens a new Claude
//  chat with the prompt PRE-FILLED (claude.ai/new?q=…) so the user never
//  retypes the task — they just press Enter. (macOS offers no API to inject
//  and submit into Claude Desktop directly; prefill + clipboard is the
//  closest the platform allows.)
//

import SwiftUI

@MainActor
enum ClaudeHandoff {
    /// Copy the prompt and open a prefilled Claude chat.
    static func send(_ prompt: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        var components = URLComponents(string: "https://claude.ai/new")!
        components.queryItems = [URLQueryItem(name: "q", value: prompt)]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Prebuilt mail prompts

    static func draftReply(to message: MailMessage, accountEmail: String) -> String {
        """
        Using the hyperview MCP tools: call mail_get_message with account "\(accountEmail)", \
        mailbox "\(message.mailboxPath)", uid \(message.uid) to read the email \
        "\(message.subject)" from \(message.fromName.isEmpty ? message.fromAddress : message.fromName). \
        Then draft a reply for me (use mail_draft with account "\(accountEmail)" and to \
        "\(message.fromAddress)"). Match my tone: concise and friendly.
        """
    }

    static func summarize(_ message: MailMessage, accountEmail: String) -> String {
        """
        Using the hyperview MCP tools: call mail_get_message with account "\(accountEmail)", \
        mailbox "\(message.mailboxPath)", uid \(message.uid), then give me a brief summary of \
        the email "\(message.subject)" and list any action items or deadlines it contains.
        """
    }

    static func briefing() -> String {
        "Using the hyperview MCP tools, call dashboard_briefing and give me a concise morning briefing: what needs my attention, in priority order."
    }
}
