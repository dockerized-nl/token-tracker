import Foundation
import Combine

// MARK: - Raw Codex rollout JSONL decoding

private struct CxLine: Decodable {
    let type: String?
    let timestamp: String?
    let payload: CxPayload?
}
private struct CxPayload: Decodable {
    let type: String?
    let id: String?            // session_meta
    let cwd: String?           // session_meta / turn_context
    let model: String?         // turn_context
    let info: CxInfo?          // token_count
    let rate_limits: CxRateLimits?
}
private struct CxInfo: Decodable {
    let total_token_usage: CxUsage?
    let last_token_usage: CxUsage?
    let model_context_window: Int?
}
private struct CxUsage: Decodable {
    let input_tokens: Int?
    let cached_input_tokens: Int?
    let output_tokens: Int?
    let reasoning_output_tokens: Int?
    let total_tokens: Int?
}
private struct CxRateLimits: Decodable {
    let primary: CxWindow?
    let secondary: CxWindow?
    let credits: CxCredits?
}
private struct CxWindow: Decodable {
    let used_percent: Double?
    let window_minutes: Int?
    let resets_at: Double?
}
private struct CxCredits: Decodable {
    let has_credits: Bool?
    let unlimited: Bool?
    let balance: Double?
    let plan_type: String?
}

// MARK: - Domain model

struct CodexRecord {
    let date: Date
    let sessionId: String
    let project: String
    let model: String
    let input: Int          // delta this turn
    let cachedInput: Int    // subset of input
    let output: Int         // delta this turn
    let reasoning: Int      // subset of output
    var total: Int { input + output }
}

struct CodexSessionAgg: Identifiable {
    let id: String
    let project: String
    let model: String
    let turns: Int
    let total: Int
    let input: Int
    let output: Int
    let reasoning: Int
    let lastActivity: Date
}

/// Latest rate-limit / credit snapshot observed in the logs.
struct RateInfo {
    let date: Date
    let primaryPercent: Double?
    let primaryWindowMinutes: Int?
    let primaryResetsAt: Date?
    let secondaryPercent: Double?
    let secondaryWindowMinutes: Int?
    let secondaryResetsAt: Date?
    let creditsBalance: Double?
    let hasCredits: Bool
    let planType: String?
}

// MARK: - Store

@MainActor
final class CodexStore: ObservableObject {
    @Published var records: [CodexRecord] = []
    @Published var isScanning = false
    @Published var fileCount = 0
    @Published var lastScan: Date?
    @Published var errorMessage: String?
    @Published var latestRate: RateInfo?
    @Published var contextWindow: Int = 0

    var logsRoot: URL {
        let custom = UserDefaults.standard.string(forKey: "codexLogsPath")
        if let custom, !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    // Totals -------------------------------------------------------------
    var totalTokens: Int { records.reduce(0) { $0 + $1.total } }
    var totalInput: Int { records.reduce(0) { $0 + $1.input } }
    var totalOutput: Int { records.reduce(0) { $0 + $1.output } }
    var totalReasoning: Int { records.reduce(0) { $0 + $1.reasoning } }
    var totalCachedInput: Int { records.reduce(0) { $0 + $1.cachedInput } }
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
    func sessions(limit: Int? = nil) -> [CodexSessionAgg] {
        var map: [String: (proj: String, model: String, turns: Int, t: Int, i: Int, o: Int, r: Int, last: Date)] = [:]
        for rec in records {
            var e = map[rec.sessionId] ?? (rec.project, rec.model, 0, 0, 0, 0, 0, rec.date)
            e.turns += 1
            e.t += rec.total; e.i += rec.input; e.o += rec.output; e.r += rec.reasoning
            if rec.date > e.last { e.last = rec.date }
            map[rec.sessionId] = e
        }
        var out = map.map { (k, v) in
            CodexSessionAgg(id: k, project: v.proj, model: v.model, turns: v.turns,
                            total: v.t, input: v.i, output: v.o, reasoning: v.r, lastActivity: v.last)
        }
        out.sort { $0.lastActivity > $1.lastActivity }
        if let limit { return Array(out.prefix(limit)) }
        return out
    }

    // Per-day / per-hour (reuse TimeBucket from ClaudeUsage) --------------
    func perDay(days: Int = 30) -> [TimeBucket] {
        bucket(by: .day, count: days, fmt: "MMM d")
    }
    func perHour(hours: Int = 24) -> [TimeBucket] {
        bucket(by: .hour, count: hours, fmt: "HH:00")
    }
    private func bucket(by unit: Calendar.Component, count: Int, fmt fmtStr: String) -> [TimeBucket] {
        let cal = Calendar.current
        let anchor: Date
        if unit == .day { anchor = cal.startOfDay(for: Date()) }
        else {
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
            anchor = cal.date(from: comps) ?? Date()
        }
        var buckets: [Date: (t: Int, i: Int, o: Int, r: Int)] = [:]
        guard let earliest = cal.date(byAdding: unit, value: -(count - 1), to: anchor) else { return [] }
        let comps: Set<Calendar.Component> = unit == .day
            ? [.year, .month, .day] : [.year, .month, .day, .hour]
        for rec in records where rec.date >= earliest {
            guard let key = cal.date(from: cal.dateComponents(comps, from: rec.date)) else { continue }
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.t += rec.total; e.i += rec.input; e.o += rec.output; e.r += rec.reasoning
            buckets[key] = e
        }
        let fmt = DateFormatter(); fmt.dateFormat = fmtStr
        var result: [TimeBucket] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let key = cal.date(byAdding: unit, value: -offset, to: anchor) else { continue }
            let e = buckets[key] ?? (0, 0, 0, 0)
            result.append(TimeBucket(id: key, label: fmt.string(from: key),
                                     total: e.t, input: e.i, output: e.o, cacheRead: e.r))
        }
        return result
    }

    func models() -> [ModelAgg] {
        var map: [String: (t: Int, m: Int)] = [:]
        for rec in records {
            var e = map[rec.model] ?? (0, 0)
            e.t += rec.total; e.m += 1
            map[rec.model] = e
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
                self.latestRate = r.latestRate
                self.contextWindow = r.contextWindow
                self.lastScan = Date()
                self.isScanning = false
                if r.records.isEmpty && r.fileCount == 0 {
                    self.errorMessage = "No Codex sessions found at \(root.path)"
                }
            }
        }
    }

    struct ScanResult { let records: [CodexRecord]; let fileCount: Int; let latestRate: RateInfo?; let contextWindow: Int }

    nonisolated static func scan(root: URL) -> ScanResult {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else {
            return ScanResult(records: [], fileCount: 0, latestRate: nil, contextWindow: 0)
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? iso2.date(from: s)
        }
        let decoder = JSONDecoder()

        var allRecords: [CodexRecord] = []
        var fileCount = 0
        var latestRate: RateInfo?
        var latestContext = 0

        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: url) else { continue }
            fileCount += 1

            var sessionId = url.deletingPathExtension().lastPathComponent
            var cwd = ""
            var model = "codex"
            var events: [(date: Date, u: CxUsage)] = []

            for lineData in data.split(separator: 0x0A) {
                guard let line = try? decoder.decode(CxLine.self, from: Data(lineData)),
                      let p = line.payload else { continue }
                let date = parseDate(line.timestamp) ?? Date()
                switch line.type {
                case "session_meta":
                    if let id = p.id { sessionId = id }
                    if let c = p.cwd { cwd = c }
                case "turn_context":
                    if let m = p.model, !m.isEmpty { model = m }
                    if cwd.isEmpty, let c = p.cwd { cwd = c }
                case "event_msg":
                    if p.type == "token_count" {
                        if let info = p.info, let cum = info.total_token_usage {
                            events.append((date, cum))
                            if let w = info.model_context_window { latestContext = w }
                        }
                        if let rl = p.rate_limits {
                            let r = RateInfo(
                                date: date,
                                primaryPercent: rl.primary?.used_percent,
                                primaryWindowMinutes: rl.primary?.window_minutes,
                                primaryResetsAt: rl.primary?.resets_at.map { Date(timeIntervalSince1970: $0) },
                                secondaryPercent: rl.secondary?.used_percent,
                                secondaryWindowMinutes: rl.secondary?.window_minutes,
                                secondaryResetsAt: rl.secondary?.resets_at.map { Date(timeIntervalSince1970: $0) },
                                creditsBalance: rl.credits?.balance,
                                hasCredits: rl.credits?.has_credits ?? false,
                                planType: rl.credits?.plan_type)
                            if latestRate == nil || date > latestRate!.date { latestRate = r }
                        }
                    }
                default: break
                }
            }

            // Cumulative -> per-turn deltas.
            let project = prettyProject(cwd: cwd, fallback: sessionId)
            events.sort { $0.date < $1.date }
            var pIn = 0, pCached = 0, pOut = 0, pReason = 0
            for (date, u) in events {
                let din = max(0, (u.input_tokens ?? 0) - pIn)
                let dcached = max(0, (u.cached_input_tokens ?? 0) - pCached)
                let dout = max(0, (u.output_tokens ?? 0) - pOut)
                let dreason = max(0, (u.reasoning_output_tokens ?? 0) - pReason)
                if din + dout > 0 {
                    allRecords.append(CodexRecord(date: date, sessionId: sessionId, project: project,
                                                  model: model, input: din, cachedInput: dcached,
                                                  output: dout, reasoning: dreason))
                }
                pIn = u.input_tokens ?? pIn
                pCached = u.cached_input_tokens ?? pCached
                pOut = u.output_tokens ?? pOut
                pReason = u.reasoning_output_tokens ?? pReason
            }
        }
        return ScanResult(records: allRecords, fileCount: fileCount,
                          latestRate: latestRate, contextWindow: latestContext)
    }

    nonisolated static func prettyProject(cwd: String, fallback: String) -> String {
        if !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return String(fallback.prefix(8))
    }
}

/// Formats a window length (minutes) as a friendly label.
func windowLabel(_ minutes: Int?) -> String {
    guard let m = minutes else { return "" }
    if m % (60 * 24) == 0 { return "\(m / (60 * 24))d window" }
    if m % 60 == 0 { return "\(m / 60)h window" }
    return "\(m)m window"
}
