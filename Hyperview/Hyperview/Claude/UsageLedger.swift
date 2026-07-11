//
//  UsageLedger.swift
//  Hyperview
//
//  Local record of every Anthropic API call Hyperview makes (chat turns and
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
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func entries() -> [UsageEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([UsageEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
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
