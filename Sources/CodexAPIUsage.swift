import Foundation
import Combine

// MARK: - OpenAI Admin API decoding
//
// Usage report:  GET /v1/organization/usage/completions
// Cost report:   GET /v1/organization/costs
// Auth:          Authorization: Bearer <admin key>
// The admin key starts with `sk-admin-…` and is distinct from a normal API key.
// `start_time` / `end_time` are Unix seconds; cost `amount.value` is USD (a float).

private struct OAIUsageResponse: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable {
        let start_time: Int
        let results: [Result]
    }
    struct Result: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let input_cached_tokens: Int?
        let num_model_requests: Int?
        let model: String?
    }
}

private struct OAICostResponse: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable {
        let start_time: Int
        let results: [Result]
    }
    struct Result: Decodable {
        let amount: Amount?
        struct Amount: Decodable {
            let value: Double?
            let currency: String?
        }
    }
}

@MainActor
final class CodexAPIStore: ObservableObject, APIUsageStore {
    @Published var days: [APIDayUsage] = []
    @Published var modelTotals: [APIModelUsage] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetch: Date?

    let providerTitle = "Codex API"
    let keyPlaceholder = "sk-admin-…"
    let settingsHint = "Add your OpenAI Admin API key in Settings to chart organization spend and token usage from the Usage & Costs API."
    let windowDays = 30

    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("codex_api_usage.json")
        load()
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "openaiAdminKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "openaiAdminKey") }
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
        guard hasKey else { errorMessage = "Add your OpenAI Admin API key in Settings."; return }
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
        let startTime = Int(apiWindowStart(daysAgo: windowDays).timeIntervalSince1970)
        let limit = max(7, windowDays + 1)
        let headers = ["Authorization": "Bearer \(key)"]

        // --- Usage (tokens), grouped by model ---
        var usageComps = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
        usageComps.queryItems = [
            URLQueryItem(name: "start_time", value: "\(startTime)"),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by", value: "model"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        let usageData = try await apiGET(usageComps.url!, headers: headers)
        let usage = try JSONDecoder().decode(OAIUsageResponse.self, from: usageData)

        // --- Cost (USD), aggregated per bucket ---
        var costComps = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        costComps.queryItems = [
            URLQueryItem(name: "start_time", value: "\(startTime)"),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        let costData = try await apiGET(costComps.url!, headers: headers)
        let cost = try JSONDecoder().decode(OAICostResponse.self, from: costData)

        // --- Merge into normalised days + per-model totals ---
        var byDay: [Date: APIDayUsage] = [:]
        var byModel: [String: APIModelUsage] = [:]

        func day(from unix: Int) -> Date {
            apiUTCCalendar.startOfDay(for: Date(timeIntervalSince1970: Double(unix)))
        }

        for bucket in usage.data {
            let d = day(from: bucket.start_time)
            var entry = byDay[d] ?? APIDayUsage(day: d)
            for r in bucket.results {
                let cached = r.input_cached_tokens ?? 0
                // OpenAI `input_tokens` already includes the cached portion, so split
                // it out to keep the four token categories disjoint.
                let uncachedInput = max(0, (r.input_tokens ?? 0) - cached)
                let output = r.output_tokens ?? 0
                entry.inputTokens += uncachedInput
                entry.cacheReadTokens += cached
                entry.outputTokens += output

                let name = r.model ?? "unknown"
                var m = byModel[name] ?? APIModelUsage(model: name)
                m.inputTokens += uncachedInput
                m.cacheReadTokens += cached
                m.outputTokens += output
                byModel[name] = m
            }
            byDay[d] = entry
        }

        for bucket in cost.data {
            let d = day(from: bucket.start_time)
            var entry = byDay[d] ?? APIDayUsage(day: d)
            for r in bucket.results {
                entry.costUSD += r.amount?.value ?? 0
            }
            byDay[d] = entry
        }

        let sortedDays = byDay.values.sorted { $0.day < $1.day }
        let sortedModels = byModel.values
            .filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }
        return (sortedDays, sortedModels)
    }
}
