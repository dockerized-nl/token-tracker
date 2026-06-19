import Foundation
import Combine

// MARK: - Shared models for provider usage/cost reporting APIs
//
// Both Claude (Anthropic Admin API) and Codex (OpenAI Admin API) expose
// historical usage + cost reports bucketed by day. We normalise them into the
// same shape so a single dashboard section can render either provider.

/// One UTC day of aggregated API usage + cost.
/// `inputTokens` is the *uncached* input portion, so the four token fields are
/// disjoint and `totalTokens` never double-counts cache reads.
struct APIDayUsage: Codable, Identifiable {
    var id: Date { day }
    let day: Date                 // UTC midnight of the bucket
    var inputTokens: Int = 0      // uncached input
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0 // cache creation (Anthropic only; 0 for OpenAI)
    var costUSD: Double = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

/// Per-model token totals over the reporting window.
struct APIModelUsage: Codable, Identifiable {
    var id: String { model }
    let model: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

/// On-disk snapshot so the dashboard shows the last result before the first refresh.
struct APIUsageSnapshot: Codable {
    var days: [APIDayUsage] = []
    var models: [APIModelUsage] = []
    var lastFetch: Date?
}

// MARK: - Store protocol

/// Common surface implemented by `ClaudeAPIStore` and `CodexAPIStore`,
/// letting `APIUsageSection` render either one.
@MainActor
protocol APIUsageStore: ObservableObject {
    var providerTitle: String { get }   // e.g. "Claude API"
    var keyPlaceholder: String { get }   // settings field placeholder
    var settingsHint: String { get }     // shown when no key is configured
    var windowDays: Int { get }

    var hasKey: Bool { get }
    var isLoading: Bool { get }
    var errorMessage: String? { get }
    var lastFetch: Date? { get }
    var days: [APIDayUsage] { get }
    var modelTotals: [APIModelUsage] { get }   // sorted, highest tokens first

    func refresh()
}

extension APIUsageStore {
    var totalCost: Double { days.reduce(0) { $0 + $1.costUSD } }
    var totalTokens: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var totalInput: Int { days.reduce(0) { $0 + $1.inputTokens } }
    var totalOutput: Int { days.reduce(0) { $0 + $1.outputTokens } }
    var totalCacheRead: Int { days.reduce(0) { $0 + $1.cacheReadTokens } }
    var totalCacheWrite: Int { days.reduce(0) { $0 + $1.cacheWriteTokens } }

    /// "Today" uses the UTC day bucket(s) so it lines up with the API's bucketing.
    private var todayStartUTC: Date { apiUTCCalendar.startOfDay(for: Date()) }
    var costToday: Double { days.filter { $0.day >= todayStartUTC }.reduce(0) { $0 + $1.costUSD } }
    var tokensToday: Int { days.filter { $0.day >= todayStartUTC }.reduce(0) { $0 + $1.totalTokens } }
}

// MARK: - Helpers shared by the provider stores

/// A Gregorian calendar pinned to UTC, matching how both APIs bucket days.
let apiUTCCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// Start of the reporting window: midnight UTC, `windowDays` ago.
func apiWindowStart(daysAgo: Int) -> Date {
    let today = apiUTCCalendar.startOfDay(for: Date())
    return today.addingTimeInterval(-Double(daysAgo) * 86_400)
}

/// Errors surfaced to the dashboard.
struct APIUsageError: Error { let message: String }

/// Performs a GET, validating the HTTP status, and returns the body bytes.
func apiGET(_ url: URL, headers: [String: String]) async throws -> Data {
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("TokenTracker/1.0 (+https://github.com/dockerized/token-tracker)",
                 forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
        throw APIUsageError(message: "No HTTP response")
    }
    guard http.statusCode == 200 else {
        switch http.statusCode {
        case 401: throw APIUsageError(message: "Invalid admin key (401).")
        case 403: throw APIUsageError(message: "Key lacks permission for usage reports (403). Use an organization admin key.")
        case 404: throw APIUsageError(message: "Usage endpoint not found (404). Org/admin access required.")
        case 429: throw APIUsageError(message: "Rate limited (429). Try again shortly.")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            let snippet = body.prefix(160)
            throw APIUsageError(message: "API error \(http.statusCode)\(snippet.isEmpty ? "" : ": \(snippet)")")
        }
    }
    return data
}

/// Compact USD formatting: `$1.23`, or 4 decimals for sub-cent amounts.
func formatUSD(_ v: Double) -> String {
    if v != 0 && abs(v) < 0.01 { return String(format: "$%.4f", v) }
    return String(format: "$%.2f", v)
}
