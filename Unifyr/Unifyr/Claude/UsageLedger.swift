//
//  UsageLedger.swift
//  Unifyr
//
//  Local record of every Anthropic API call Unifyr makes (chat turns and
//  daily briefings) with token counts per model, so the Usage pane can show a
//  cost picture like console.anthropic.com — without needing an Admin API key.
//  Costs are ESTIMATES from list prices (cache writes 1.25×, cache reads 0.1×
//  the input rate); the Anthropic console remains the billing ground truth.
//

import Foundation

nonisolated struct UsageEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var model: String
    var input: Int
    var output: Int
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    /// "chat" or "briefing".
    var source: String
}

@MainActor
enum UsageLedger {
    private static let key = "claude.usageLedger"
    private static let cap = 5000

    /// In-memory working copy: `record` used to decode + re-encode the whole
    /// (up to 5000-entry) array on the main actor per streamed turn. Now the
    /// array is decoded once, appended in memory, and flushed after a short
    /// quiet gap (tool-looping turns record up to ~12× in quick succession).
    private static var cache: [UsageEntry]?
    private static var flushTask: Task<Void, Never>?

    static func record(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        source: String
    ) {
        guard input + output + cacheRead + cacheWrite > 0 else { return }
        var all = entries()
        all.append(UsageEntry(
            model: model, input: input, output: output,
            cacheRead: cacheRead, cacheWrite: cacheWrite, source: source
        ))
        if all.count > cap { all.removeFirst(all.count - cap) }
        cache = all
        scheduleFlush()
    }

    static func entries() -> [UsageEntry] {
        if let cache { return cache }
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([UsageEntry].self, from: data) else {
            cache = []
            return []
        }
        cache = decoded
        return decoded
    }

    static func clear() {
        cache = []
        flushTask?.cancel()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private static func flush() {
        guard let cache, let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// List price $/MTok (input, output) by model family.
    static func rates(for model: String) -> (input: Double, output: Double) {
        if model.contains("fable") || model.contains("mythos") { return (10, 50) }
        if model.contains("opus") { return (5, 25) }
        if model.contains("sonnet") { return (3, 15) }
        if model.contains("haiku") { return (1, 5) }
        return (5, 25)
    }

    /// Estimated $ for one entry.
    static func cost(of entry: UsageEntry) -> Double {
        let rate = rates(for: entry.model)
        let inputDollars = Double(entry.input) * rate.input
            + Double(entry.cacheWrite) * rate.input * 1.25
            + Double(entry.cacheRead) * rate.input * 0.1
        let outputDollars = Double(entry.output) * rate.output
        return (inputDollars + outputDollars) / 1_000_000
    }

    /// "claude-sonnet-5" → "Sonnet 5" for display.
    nonisolated static func displayName(for model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .split(separator: "-")
            .map { part in
                part.first.map { String($0).uppercased() + part.dropFirst() } ?? String(part)
            }
            .joined(separator: " ")
    }
}
