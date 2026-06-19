import Foundation
import Combine

// MARK: - Anthropic Admin API decoding
//
// Usage report:  GET /v1/organizations/usage_report/messages
// Cost report:   GET /v1/organizations/cost_report
// Auth:          x-api-key: <admin key>  +  anthropic-version: 2023-06-01
// The admin key starts with `sk-ant-admin01-…` and is distinct from a normal API key.

private struct AnthUsageResponse: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable {
        let starting_at: String
        let results: [Result]
    }
    struct Result: Decodable {
        let uncached_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let output_tokens: Int?
        let cache_creation: CacheCreation?
        let model: String?
    }
    struct CacheCreation: Decodable {
        let ephemeral_1h_input_tokens: Int?
        let ephemeral_5m_input_tokens: Int?
    }
}

private struct AnthCostResponse: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable {
        let starting_at: String
        let results: [Result]
    }
    struct Result: Decodable {
        let amount: String?     // lowest currency units (cents) as a decimal string
        let currency: String?
    }
}

@MainActor
final class ClaudeAPIStore: ObservableObject, APIUsageStore {
    @Published var days: [APIDayUsage] = []
    @Published var modelTotals: [APIModelUsage] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetch: Date?

    let providerTitle = "Claude API"
    let keyPlaceholder = "sk-ant-admin01-…"
    let settingsHint = "Add your Anthropic Admin API key in Settings to chart organization spend and token usage from the Usage & Cost API."
    let windowDays = 30

    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("claude_api_usage.json")
        load()
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "anthropicAdminKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "anthropicAdminKey") }
    }
    var hasKey: Bool { !apiKey.isEmpty }

    // MARK: Persistence
    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? JSONDecoder().decode(APIUsageSnapshot.self, from: data) else { return }
        days = snap.days
        modelTotals = snap.models
        lastFetch = snap.lastFetch
    }
    private func save() {
        let snap = APIUsageSnapshot(days: days, models: modelTotals, lastFetch: lastFetch)
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: storeURL) }
    }

    // MARK: Fetch
    func refresh() {
        guard hasKey else { errorMessage = "Add your Anthropic Admin API key in Settings."; return }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let key = apiKey
        let window = windowDays
        Task {
            do {
                let result = try await Self.fetch(key: key, windowDays: window)
                self.days = result.days
                self.modelTotals = result.models
                self.lastFetch = Date()
                self.save()
            } catch {
                self.errorMessage = (error as? APIUsageError)?.message ?? error.localizedDescription
            }
            self.isLoading = false
        }
    }

    nonisolated static func fetch(key: String, windowDays: Int) async throws -> (days: [APIDayUsage], models: [APIModelUsage]) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")
        let startingAt = iso.string(from: apiWindowStart(daysAgo: windowDays))
        let limit = max(7, windowDays + 1)

        let headers = [
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
        ]

        // --- Usage (tokens), grouped by model ---
        var usageComps = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
        usageComps.queryItems = [
            URLQueryItem(name: "starting_at", value: startingAt),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by[]", value: "model"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        let usageData = try await apiGET(usageComps.url!, headers: headers)
        let usage = try JSONDecoder().decode(AnthUsageResponse.self, from: usageData)

        // --- Cost (USD), aggregated per bucket ---
        var costComps = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        costComps.queryItems = [
            URLQueryItem(name: "starting_at", value: startingAt),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        let costData = try await apiGET(costComps.url!, headers: headers)
        let cost = try JSONDecoder().decode(AnthCostResponse.self, from: costData)

        // --- Merge into normalised days + per-model totals ---
        var byDay: [Date: APIDayUsage] = [:]
        var byModel: [String: APIModelUsage] = [:]

        func parseDay(_ s: String) -> Date? {
            guard let d = iso.date(from: s) else { return nil }
            return apiUTCCalendar.startOfDay(for: d)
        }

        for bucket in usage.data {
            guard let day = parseDay(bucket.starting_at) else { continue }
            var entry = byDay[day] ?? APIDayUsage(day: day)
            for r in bucket.results {
                let input = r.uncached_input_tokens ?? 0
                let output = r.output_tokens ?? 0
                let cacheRead = r.cache_read_input_tokens ?? 0
                let cacheWrite = (r.cache_creation?.ephemeral_1h_input_tokens ?? 0)
                               + (r.cache_creation?.ephemeral_5m_input_tokens ?? 0)
                entry.inputTokens += input
                entry.outputTokens += output
                entry.cacheReadTokens += cacheRead
                entry.cacheWriteTokens += cacheWrite

                let name = r.model ?? "unknown"
                var m = byModel[name] ?? APIModelUsage(model: name)
                m.inputTokens += input
                m.outputTokens += output
                m.cacheReadTokens += cacheRead
                m.cacheWriteTokens += cacheWrite
                byModel[name] = m
            }
            byDay[day] = entry
        }

        for bucket in cost.data {
            guard let day = parseDay(bucket.starting_at) else { continue }
            var entry = byDay[day] ?? APIDayUsage(day: day)
            for r in bucket.results {
                // amount is in cents → dollars
                entry.costUSD += (Double(r.amount ?? "0") ?? 0) / 100.0
            }
            byDay[day] = entry
        }

        let sortedDays = byDay.values.sorted { $0.day < $1.day }
        let sortedModels = byModel.values
            .filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }
        return (sortedDays, sortedModels)
    }
}
