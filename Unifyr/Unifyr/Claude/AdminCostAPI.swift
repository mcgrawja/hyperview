//
//  AdminCostAPI.swift
//  Unifyr
//
//  Anthropic Usage & Cost Admin API — the same data as the console's Cost
//  page. Requires an ADMIN API key (sk-ant-admin01-…), which Anthropic only
//  issues to ORGANIZATIONS: an individual account must first create an org in
//  Console → Settings → Organization. Fetched strictly on demand (Refresh).
//
//  GET /v1/organizations/cost_report?starting_at=…&ending_at=…&group_by[]=description
//  → { data: [{ starting_at, ending_at, results: [{ amount (decimal string,
//    CENTS), currency, model?, description?, … }] }], has_more, next_page }
//

import Foundation

/// One day of billed cost, in dollars, with a per-model split when available.
nonisolated struct RemoteCostDay: Identifiable, Sendable {
    let day: Date
    var totalDollars: Double
    /// model (or description when the model field is absent) → dollars.
    var byModel: [String: Double]
    var id: Date { day }
}

nonisolated enum AdminCostAPIError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            if status == 401 || status == 403 {
                return "The Admin key was rejected (\(status)). Admin keys require an ORGANIZATION — individual accounts must first create one in Console → Settings → Organization, then mint an Admin API key."
            }
            return "Cost API error \(status): \(body)"
        }
    }
}

nonisolated enum AdminCostAPI {
    /// Daily billed costs for the trailing `days`, grouped by description so
    /// each day splits by model.
    static func costReport(adminKey: String, days: Int = 30) async throws -> [RemoteCostDay] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let end = Date()
        let start = Calendar.current.startOfDay(for: end.addingTimeInterval(-TimeInterval(days) * 86_400))

        var buckets: [Date: RemoteCostDay] = [:]
        var page: String?
        var guardCounter = 0
        repeat {
            guardCounter += 1
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            var queryItems = [
                URLQueryItem(name: "starting_at", value: formatter.string(from: start)),
                URLQueryItem(name: "ending_at", value: formatter.string(from: end)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "group_by[]", value: "description"),
                URLQueryItem(name: "limit", value: "31"),
            ]
            if let page { queryItems.append(URLQueryItem(name: "page", value: page)) }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                throw AdminCostAPIError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
            }
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dayBuckets = parsed["data"] as? [[String: Any]] else {
                throw AdminCostAPIError.http(200, "unexpected response shape")
            }

            for bucket in dayBuckets {
                guard let startString = bucket["starting_at"] as? String,
                      let day = formatter.date(from: startString) else { continue }
                var entry = buckets[day] ?? RemoteCostDay(day: day, totalDollars: 0, byModel: [:])
                for result in (bucket["results"] as? [[String: Any]]) ?? [] {
                    // "amount" is a decimal string in CENTS.
                    guard let amountString = result["amount"] as? String,
                          let cents = Double(amountString) else { continue }
                    let dollars = cents / 100
                    entry.totalDollars += dollars
                    let label = (result["model"] as? String)
                        ?? (result["description"] as? String)
                        ?? "Other"
                    entry.byModel[label, default: 0] += dollars
                }
                buckets[day] = entry
            }

            let hasMore = (parsed["has_more"] as? Bool) ?? false
            page = hasMore ? parsed["next_page"] as? String : nil
        } while page != nil && guardCounter < 10

        return buckets.values.sorted { $0.day > $1.day }
    }
}
