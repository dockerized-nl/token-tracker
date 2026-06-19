import Foundation
import Combine

// MARK: - Raw JSONL decoding (minimal subset of the Claude Code log line)

private struct RawLine: Decodable {
    let type: String?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let message: RawMessage?
}
private struct RawMessage: Decodable {
    let model: String?
    let usage: RawUsage?
}
private struct RawUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
}

// MARK: - Domain model

struct UsageRecord {
    let date: Date
    let sessionId: String
    let project: String
    let model: String
    let input: Int
    let output: Int
    let cacheCreate: Int
    let cacheRead: Int
    var total: Int { input + output + cacheCreate + cacheRead }
    /// "Billable-style" tokens people usually think of (excludes cache reads).
    var io: Int { input + output + cacheCreate }
}

struct SessionAgg: Identifiable {
    let id: String
    let project: String
    let messages: Int
    let total: Int
    let input: Int
    let output: Int
    let cacheCreate: Int
    let cacheRead: Int
    let lastActivity: Date
}

struct TimeBucket: Identifiable {
    let id: Date
    let label: String
    let total: Int
    let input: Int
    let output: Int
    let cacheRead: Int
}

struct ModelAgg: Identifiable {
    let id: String       // model name
    let total: Int
    let messages: Int
}

// MARK: - Store

@MainActor
final class ClaudeStore: ObservableObject {
    @Published var records: [UsageRecord] = []
    @Published var isScanning = false
    @Published var fileCount = 0
    @Published var lastScan: Date?
    @Published var errorMessage: String?

    var logsRoot: URL {
        let custom = UserDefaults.standard.string(forKey: "claudeLogsPath")
        if let custom, !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
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

    var tokensToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return tokens(since: start)
    }

    var tokensThisHour: Int {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
        let start = cal.date(from: comps) ?? Date()
        return tokens(since: start)
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

    // Per-day (last `days` days, oldest -> newest) -----------------------
    func perDay(days: Int = 30) -> [TimeBucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var buckets: [Date: (t: Int, i: Int, o: Int, cr: Int)] = [:]
        guard let earliest = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        for r in records where r.date >= earliest {
            let day = cal.startOfDay(for: r.date)
            var e = buckets[day] ?? (0, 0, 0, 0)
            e.t += r.total; e.i += r.input; e.o += r.output; e.cr += r.cacheRead
            buckets[day] = e
        }
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
        var result: [TimeBucket] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let e = buckets[day] ?? (0, 0, 0, 0)
            result.append(TimeBucket(id: day, label: fmt.string(from: day),
                                     total: e.t, input: e.i, output: e.o, cacheRead: e.cr))
        }
        return result
    }

    // Per-hour (last `hours` hours, oldest -> newest) --------------------
    func perHour(hours: Int = 24) -> [TimeBucket] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
        let thisHour = cal.date(from: comps) ?? Date()
        var buckets: [Date: (t: Int, i: Int, o: Int, cr: Int)] = [:]
        guard let earliest = cal.date(byAdding: .hour, value: -(hours - 1), to: thisHour) else { return [] }
        for r in records where r.date >= earliest {
            let hc = cal.dateComponents([.year, .month, .day, .hour], from: r.date)
            guard let h = cal.date(from: hc) else { continue }
            var e = buckets[h] ?? (0, 0, 0, 0)
            e.t += r.total; e.i += r.input; e.o += r.output; e.cr += r.cacheRead
            buckets[h] = e
        }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:00"
        var result: [TimeBucket] = []
        for offset in stride(from: hours - 1, through: 0, by: -1) {
            guard let h = cal.date(byAdding: .hour, value: -offset, to: thisHour) else { continue }
            let e = buckets[h] ?? (0, 0, 0, 0)
            result.append(TimeBucket(id: h, label: fmt.string(from: h),
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
            let result = Self.scan(root: root)
            await MainActor.run {
                self.records = result.records
                self.fileCount = result.fileCount
                self.lastScan = Date()
                self.isScanning = false
                if result.records.isEmpty && result.fileCount == 0 {
                    self.errorMessage = "No log files found at \(root.path)"
                }
            }
        }
    }

    nonisolated static func scan(root: URL) -> (records: [UsageRecord], fileCount: Int) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else {
            return ([], 0)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()
        var records: [UsageRecord] = []
        var fileCount = 0

        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: url) else { continue }
            fileCount += 1
            // Project name from the parent directory of the file.
            let projectDir = url.deletingLastPathComponent().lastPathComponent
            let project = prettyProject(projectDir)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let bytes = raw.bindMemory(to: UInt8.self)
                var start = 0
                let nl = UInt8(ascii: "\n")
                var i = 0
                let count = bytes.count
                while i <= count {
                    if i == count || bytes[i] == nl {
                        if i > start {
                            let lineData = Data(bytes[start..<i])
                            if let line = try? decoder.decode(RawLine.self, from: lineData),
                               line.type == "assistant",
                               let u = line.message?.usage,
                               let ts = line.timestamp {
                                let date = iso.date(from: ts) ?? isoNoFrac.date(from: ts) ?? Date()
                                let rec = UsageRecord(
                                    date: date,
                                    sessionId: line.sessionId ?? "unknown",
                                    project: project,
                                    model: line.message?.model ?? "unknown",
                                    input: u.input_tokens ?? 0,
                                    output: u.output_tokens ?? 0,
                                    cacheCreate: u.cache_creation_input_tokens ?? 0,
                                    cacheRead: u.cache_read_input_tokens ?? 0)
                                records.append(rec)
                            }
                        }
                        start = i + 1
                    }
                    i += 1
                }
            }
        }
        return (records, fileCount)
    }

    /// Turns "-Users-jessemirz-Documents-foo" into "foo".
    nonisolated static func prettyProject(_ dir: String) -> String {
        let parts = dir.split(separator: "-").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? dir
    }
}
