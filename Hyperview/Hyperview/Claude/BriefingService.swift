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
    /// Live day weather for the native strip (refreshed every dashboard
    /// visit; free API, no tokens).
    var weather: DayWeather?

    /// Bump when the briefing prompt/format changes so cached text regenerates.
    private static let formatVersion = "3"

    var weatherLocation: String {
        get { UserDefaults.standard.string(forKey: "briefing.location") ?? "Kingsland, GA" }
        set { UserDefaults.standard.set(newValue, forKey: "briefing.location") }
    }

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
        // Weather refreshes on every visit (free, keyless) — kicked off
        // concurrently so it never delays the text.
        Task { await refreshWeather() }

        let today = Self.dayStamp()
        let cachedDay = UserDefaults.standard.string(forKey: "briefing.date")
        let cachedText = UserDefaults.standard.string(forKey: "briefing.text")
        let cachedFormat = UserDefaults.standard.string(forKey: "briefing.format")

        if cachedDay == today, cachedFormat == Self.formatVersion, let cachedText, !cachedText.isEmpty {
            state = .ready(cachedText)
            return
        }
        await generate()
    }

    private func refreshWeather() async {
        if let fetched = await WeatherService.fetch(location: weatherLocation) {
            weather = fetched
        }
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
        // Real drive time to the first located event (MapKit; best-effort).
        let commute = await CommuteService.estimate(
            homeLocation: weatherLocation,
            briefingJSON: briefingData.content
        )

        // 2. One compact API call to write it up.
        do {
            let text = try await writeBriefing(
                apiKey: apiKey,
                briefingJSON: briefingData.content,
                unreadJSON: unreadDetail.ok ? unreadDetail.content : "[]",
                commute: commute
            )
            UserDefaults.standard.set(text, forKey: "briefing.text")
            UserDefaults.standard.set(Self.dayStamp(), forKey: "briefing.date")
            UserDefaults.standard.set(Self.formatVersion, forKey: "briefing.format")
            state = .ready(text)
        } catch {
            state = .failed("Briefing failed — try again later.")
        }
    }

    private func writeBriefing(apiKey: String, briefingJSON: String, unreadJSON: String, commute: String?) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let model = UserDefaults.standard.string(forKey: "claude.model") ?? "claude-opus-4-8"
        let weatherLine = weather?.promptSummary ?? "Weather data unavailable."
        let prompt = """
        Write Jason's daily briefing from this Hyperview data. Today is \
        \(Date().formatted(date: .complete, time: .omitted)).

        Calendar/reminders/mail data:
        \(briefingJSON)

        Unread messages detail:
        \(unreadJSON)

        \(weatherLine)
        \(commute.map { "Commute (real MapKit estimate): \($0)" } ?? "")

        Output EXACTLY this plain-text structure (skip an empty subsection; \
        no greeting, no sign-off, no markdown):

        Action Items:
          Reminders:
            ☐ <title> — due <short date/time>, <notes if any>
          Emails:
            ☐ <sender/what> — <why it needs action: unanswered, expiring, \
        deadline, warning>
        Agenda:
          <start>–<end> | <title> | <location if any>
            Commute: <the MapKit commute line, indented under its event, only \
        if one was provided above — never invent one>
        Brief:
          ☐ <one checkbox line per relevant item — schedule conflicts first, \
        then a weather caution only if the concerns are non-trivial for the \
        day's plans, then anything else worth knowing. Short lines, never a \
        paragraph. If nothing: "☐ Nothing else needs your attention.">

        Emails judgment: only list messages that plausibly need ACTION \
        (replies owed, expirations, deadlines, warnings, real people). \
        Newsletters, promos, and job alerts never appear.
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
        if let usage = parsed["usage"] as? [String: Any] {
            UsageLedger.record(
                model: model,
                input: (usage["input_tokens"] as? Int) ?? 0,
                output: (usage["output_tokens"] as? Int) ?? 0,
                cacheRead: (usage["cache_read_input_tokens"] as? Int) ?? 0,
                cacheWrite: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
                source: "briefing"
            )
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
