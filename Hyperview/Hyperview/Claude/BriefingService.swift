//
//  BriefingService.swift
//  Hyperview
//
//  The dashboard's auto-generated morning briefing — the "background
//  intelligence" only the API path can do (MCP is pull-only). Gathers the
//  cross-module dashboard_briefing data via the shared tool executor (audited
//  like every tool call), then makes ONE non-streaming API call to write it
//  up. Generates at most once per calendar day automatically; manual refresh
//  is always available. Costs nothing until an API key exists.
//

import Foundation
import Observation

@MainActor
@Observable
final class BriefingService {
    enum State: Equatable {
        case hidden          // no API key — card doesn't render
        case idle            // key present, nothing generated yet today
        case generating
        case ready(String)
        case failed(String)
    }

    var state: State = .hidden

    @ObservationIgnored private weak var mcp: MCPController?

    func attach(mcp: MCPController) {
        self.mcp = mcp
    }

    /// Called when the dashboard appears: show cached briefing, or generate
    /// automatically the first time each day.
    func refreshIfStale() async {
        guard ClaudeAuth.apiKey() != nil else {
            state = .hidden
            return
        }
        let today = Self.dayStamp()
        let cachedDay = UserDefaults.standard.string(forKey: "briefing.date")
        let cachedText = UserDefaults.standard.string(forKey: "briefing.text")

        if cachedDay == today, let cachedText, !cachedText.isEmpty {
            state = .ready(cachedText)
            return
        }
        await generate()
    }

    /// Manual refresh — always regenerates.
    func generate() async {
        guard let apiKey = ClaudeAuth.apiKey() else {
            state = .hidden
            return
        }
        guard let executor = mcp?.executor else {
            state = .failed("Tool layer unavailable.")
            return
        }
        state = .generating

        // 1. Real data via the audited tool layer.
        let briefingData = await executor.execute(name: "dashboard_briefing", arguments: [:])
        guard briefingData.ok else {
            state = .failed("Couldn't gather your data.")
            return
        }
        let unreadDetail = await executor.execute(name: "mail_unread", arguments: ["limit": 12.0])

        // 2. One compact API call to write it up.
        do {
            let text = try await writeBriefing(
                apiKey: apiKey,
                briefingJSON: briefingData.content,
                unreadJSON: unreadDetail.ok ? unreadDetail.content : "[]"
            )
            UserDefaults.standard.set(text, forKey: "briefing.text")
            UserDefaults.standard.set(Self.dayStamp(), forKey: "briefing.date")
            state = .ready(text)
        } catch {
            state = .failed("Briefing failed — try again later.")
        }
    }

    private func writeBriefing(apiKey: String, briefingJSON: String, unreadJSON: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let model = UserDefaults.standard.string(forKey: "claude.model") ?? "claude-opus-4-8"
        let prompt = """
        Write Jason's morning briefing from this Hyperview data. Today is \
        \(Date().formatted(date: .complete, time: .omitted)).

        Calendar/reminders/mail counts:
        \(briefingJSON)

        Unread messages detail:
        \(unreadJSON)

        Rules: 4-8 short lines, priority order, plain text with "•" bullets. \
        Flag schedule conflicts or urgent-looking mail first. Group unread \
        mail into what needs action vs. what can be ignored (don't list every \
        message). No greeting, no sign-off, no headers.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "thinking": ["type": "adaptive"],
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClaudeChatError.api(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(decoding: data.prefix(500), as: UTF8.self)
            )
        }
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = parsed["content"] as? [[String: Any]] else {
            throw ClaudeChatError.transport
        }
        if (parsed["stop_reason"] as? String) == "refusal" {
            throw ClaudeChatError.api(status: 200, body: "refused")
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw ClaudeChatError.transport }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
