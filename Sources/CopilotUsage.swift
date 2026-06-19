import Foundation
import Combine

// MARK: - Raw Copilot CLI events.jsonl decoding
//
// GitHub Copilot CLI writes one event per line to
//   ~/.copilot/session-state/<session-id>/events.jsonl
// The events we care about:
//
//  • session.start        → { sessionId, model, cwd }
//  • session.model_change → { newModel }
//  • assistant.message    → { model, usage: { prompt_tokens, completion_tokens,
//                                              cache_creation_input_tokens,
//                                              cache_read_input_tokens, total_tokens } }
//  • session.shutdown     → { modelMetrics: { "<model>": {
//                                requests: { count, cost },
//                                usage: { inputTokens, outputTokens,
//                                         cacheReadTokens, cacheWriteTokens } } } }
//
// Per-turn tokens come from `assistant.message`. The `requests.cost` field in
// `session.shutdown` is the GitHub "premium request" unit count, which has no
// per-message equivalent, so it is summed separately. For older CLI builds that
// only emit `session.shutdown`, we synthesise one record per model from
// `modelMetrics.*.usage` so token totals still appear.

private struct CpLine: Decodable {
    let type: String?
    let timestamp: String?
    let sessionId: String?      // sometimes present at the top level
    let data: CpData?
}
private struct CpData: Decodable {
    let sessionId: String?
    let model: String?
    let newModel: String?
    let cwd: String?
    let usage: CpUsage?
    let modelMetrics: [String: CpModelMetric]?
}
private struct CpUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
    let total_tokens: Int?
}
private struct CpModelMetric: Decodable {
    let requests: CpRequests?
    let usage: CpMetricUsage?
}
private struct CpRequests: Decodable {
    let count: Int?
    let cost: Double?
}
private struct CpMetricUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
}

// MARK: - Store
//
// Copilot reuses the shared `UsageRecord` / `SessionAgg` / `TimeBucket` /
// `ModelAgg` domain types from ClaudeUsage.swift — its four token categories
// (input / output / cache-write / cache-read) line up exactly.

@MainActor
final class CopilotStore: ObservableObject {
    @Published var records: [UsageRecord] = []
    @Published var isScanning = false
    @Published var fileCount = 0
    @Published var lastScan: Date?
    @Published var errorMessage: String?
    /// GitHub "premium request" units consumed (Σ session.shutdown requests.cost).
    @Published var premiumUnits: Double = 0
    /// Number of model requests recorded (Σ session.shutdown requests.count).
    @Published var premiumRequests: Int = 0

    var logsRoot: URL {
        let custom = UserDefaults.standard.string(forKey: "copilotLogsPath")
        if let custom, !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state", isDirectory: true)
    }

    // Derived totals ------------------------------------------------------
    var totalTokens: Int { records.reduce(0) { $0 + $1.total } }
    var totalInput: Int { records.reduce(0) { $0 + $1.input } }
    var totalOutput: Int { records.reduce(0) { $0 + $1.output } }
    var totalCacheCreate: Int { records.reduce(0) { $0 + $1.cacheCreate } }
    var totalCacheRead: Int { records.reduce(0) { $0 + $1.cacheRead } }
    var sessionCount: Int { Set(records.map(\.sessionId)).count }

    func tokens(since: Date) -> Int {
        records.lazy.filter { $0.date >= since }.reduce(0) { $0 + $1.total }
    }
    var tokensToday: Int { tokens(since: Calendar.current.startOfDay(for: Date())) }
    var tokensThisHour: Int {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
        return tokens(since: cal.date(from: comps) ?? Date())
    }

    // Per-session --------------------------------------------------------
    func sessions(limit: Int? = nil) -> [SessionAgg] {
        var map: [String: (proj: String, msgs: Int, t: Int, i: Int, o: Int, cc: Int, cr: Int, last: Date)] = [:]
        for r in records {
            var e = map[r.sessionId] ?? (r.project, 0, 0, 0, 0, 0, 0, r.date)
            e.msgs += 1
            e.t += r.total; e.i += r.input; e.o += r.output
            e.cc += r.cacheCreate; e.cr += r.cacheRead
            if r.date > e.last { e.last = r.date }
            if e.proj.isEmpty { e.proj = r.project }
            map[r.sessionId] = e
        }
        var out = map.map { (k, v) in
            SessionAgg(id: k, project: v.proj, messages: v.msgs, total: v.t,
                       input: v.i, output: v.o, cacheCreate: v.cc, cacheRead: v.cr,
                       lastActivity: v.last)
        }
        out.sort { $0.lastActivity > $1.lastActivity }
        if let limit { return Array(out.prefix(limit)) }
        return out
    }

    // Per-day / per-hour -------------------------------------------------
    func perDay(days: Int = 30) -> [TimeBucket] { bucket(by: .day, count: days, fmt: "MMM d") }
    func perHour(hours: Int = 24) -> [TimeBucket] { bucket(by: .hour, count: hours, fmt: "HH:00") }
    private func bucket(by unit: Calendar.Component, count: Int, fmt fmtStr: String) -> [TimeBucket] {
        let cal = Calendar.current
        let anchor: Date
        if unit == .day { anchor = cal.startOfDay(for: Date()) }
        else {
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
            anchor = cal.date(from: comps) ?? Date()
        }
        var buckets: [Date: (t: Int, i: Int, o: Int, cr: Int)] = [:]
        guard let earliest = cal.date(byAdding: unit, value: -(count - 1), to: anchor) else { return [] }
        let comps: Set<Calendar.Component> = unit == .day
            ? [.year, .month, .day] : [.year, .month, .day, .hour]
        for r in records where r.date >= earliest {
            guard let key = cal.date(from: cal.dateComponents(comps, from: r.date)) else { continue }
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.t += r.total; e.i += r.input; e.o += r.output; e.cr += r.cacheRead
            buckets[key] = e
        }
        let fmt = DateFormatter(); fmt.dateFormat = fmtStr
        var result: [TimeBucket] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let key = cal.date(byAdding: unit, value: -offset, to: anchor) else { continue }
            let e = buckets[key] ?? (0, 0, 0, 0)
            result.append(TimeBucket(id: key, label: fmt.string(from: key),
                                     total: e.t, input: e.i, output: e.o, cacheRead: e.cr))
        }
        return result
    }

    // Per-model ----------------------------------------------------------
    func models() -> [ModelAgg] {
        var map: [String: (t: Int, m: Int)] = [:]
        for r in records {
            var e = map[r.model] ?? (0, 0)
            e.t += r.total; e.m += 1
            map[r.model] = e
        }
        return map.map { ModelAgg(id: $0.key, total: $0.value.t, messages: $0.value.m) }
            .sorted { $0.total > $1.total }
    }

    // MARK: - Scanning

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        let root = logsRoot
        Task.detached(priority: .userInitiated) {
            let r = Self.scan(root: root)
            await MainActor.run {
                self.records = r.records
                self.fileCount = r.fileCount
                self.premiumUnits = r.premiumUnits
                self.premiumRequests = r.premiumRequests
                self.lastScan = Date()
                self.isScanning = false
                if r.records.isEmpty && r.fileCount == 0 {
                    self.errorMessage = "No Copilot sessions found at \(root.path)"
                }
            }
        }
    }

    struct ScanResult {
        let records: [UsageRecord]
        let fileCount: Int
        let premiumUnits: Double
        let premiumRequests: Int
    }

    nonisolated static func scan(root: URL) -> ScanResult {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else {
            return ScanResult(records: [], fileCount: 0, premiumUnits: 0, premiumRequests: 0)
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? iso2.date(from: s)
        }
        let decoder = JSONDecoder()

        var allRecords: [UsageRecord] = []
        var fileCount = 0
        var premiumUnits = 0.0
        var premiumRequests = 0

        for case let url as URL in en where url.lastPathComponent == "events.jsonl" {
            guard let data = try? Data(contentsOf: url) else { continue }
            fileCount += 1

            // The containing folder is the session id.
            var sessionId = url.deletingLastPathComponent().lastPathComponent
            var model = "copilot"
            var project = ""
            var fileRecords: [UsageRecord] = []
            // Last shutdown's per-model usage, used only as a fallback when no
            // assistant.message tokens were seen in this session.
            var shutdownFallback: [(date: Date, model: String, u: CpMetricUsage)] = []
            var lastEventDate = Date()

            for lineData in data.split(separator: 0x0A) {
                guard let line = try? decoder.decode(CpLine.self, from: Data(lineData)) else { continue }
                let date = parseDate(line.timestamp) ?? lastEventDate
                lastEventDate = date
                let d = line.data
                switch line.type {
                case "session.start":
                    if let id = line.sessionId ?? d?.sessionId, !id.isEmpty { sessionId = id }
                    if let m = d?.model, !m.isEmpty { model = m }
                    if let c = d?.cwd, !c.isEmpty { project = (c as NSString).lastPathComponent }
                case "session.model_change":
                    if let m = d?.newModel ?? d?.model, !m.isEmpty { model = m }
                case "assistant.message":
                    if let m = d?.model, !m.isEmpty { model = m }
                    if let u = d?.usage {
                        // Categories are treated as disjoint (Anthropic-style), so the
                        // record total stays input + output + cacheWrite + cacheRead.
                        let rec = UsageRecord(
                            date: date,
                            sessionId: sessionId,
                            project: project,
                            model: model,
                            input: u.prompt_tokens ?? 0,
                            output: u.completion_tokens ?? 0,
                            cacheCreate: u.cache_creation_input_tokens ?? 0,
                            cacheRead: u.cache_read_input_tokens ?? 0)
                        if rec.total > 0 { fileRecords.append(rec) }
                    }
                case "session.shutdown":
                    if let metrics = d?.modelMetrics {
                        for (mName, metric) in metrics {
                            premiumUnits += metric.requests?.cost ?? 0
                            premiumRequests += metric.requests?.count ?? 0
                            if let u = metric.usage { shutdownFallback.append((date, mName, u)) }
                        }
                    }
                default: break
                }
            }

            if !fileRecords.isEmpty {
                allRecords.append(contentsOf: fileRecords)
            } else if !shutdownFallback.isEmpty {
                // No per-message tokens (older CLI) — derive records from the
                // shutdown summary. inputTokens here is inclusive of cache, so
                // split the cache portions out to keep categories disjoint.
                for (date, mName, u) in shutdownFallback {
                    let cacheRead = u.cacheReadTokens ?? 0
                    let cacheWrite = u.cacheWriteTokens ?? 0
                    let input = max(0, (u.inputTokens ?? 0) - cacheRead - cacheWrite)
                    let rec = UsageRecord(
                        date: date, sessionId: sessionId, project: project,
                        model: mName, input: input, output: u.outputTokens ?? 0,
                        cacheCreate: cacheWrite, cacheRead: cacheRead)
                    if rec.total > 0 { allRecords.append(rec) }
                }
            }
        }
        return ScanResult(records: allRecords, fileCount: fileCount,
                          premiumUnits: premiumUnits, premiumRequests: premiumRequests)
    }
}
