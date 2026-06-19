import Foundation
import Combine

// MARK: - DeepSeek balance API decoding

private struct BalanceResponse: Decodable {
    let is_available: Bool
    let balance_infos: [BalanceInfo]
}
private struct BalanceInfo: Decodable {
    let currency: String
    let total_balance: String
    let granted_balance: String
    let topped_up_balance: String
}

/// A point-in-time snapshot of the DeepSeek account balance.
struct BalanceSnapshot: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let currency: String
    let total: Double
    let granted: Double
    let toppedUp: Double
}

@MainActor
final class DeepSeekStore: ObservableObject {
    @Published var snapshots: [BalanceSnapshot] = []
    @Published var isLoading = false
    @Published var isAvailable = true
    @Published var errorMessage: String?
    @Published var lastFetch: Date?

    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("deepseek_snapshots.json")
        load()
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "deepseekApiKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "deepseekApiKey") }
    }

    var hasKey: Bool { !apiKey.isEmpty }

    // Derived ------------------------------------------------------------
    var latest: BalanceSnapshot? { snapshots.last }
    var currency: String { latest?.currency ?? "USD" }

    /// Total credit consumed since the first recorded snapshot (peak-to-now,
    /// to avoid top-ups making "used" look negative).
    var creditUsed: Double {
        guard let latest else { return 0 }
        // Use the highest historical balance as the baseline of available credit.
        let peak = snapshots.map(\.total).max() ?? latest.total
        return max(0, peak - latest.total)
    }

    var creditUsedToday: Double {
        let start = Calendar.current.startOfDay(for: Date())
        let todays = snapshots.filter { $0.date >= start }
        guard let first = todays.first, let last = todays.last else {
            // fall back to last snapshot before today vs latest
            return 0
        }
        return max(0, first.total - last.total)
    }

    // MARK: - Persistence
    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let arr = try? JSONDecoder().decode([BalanceSnapshot].self, from: data) {
            snapshots = arr.sorted { $0.date < $1.date }
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: storeURL)
        }
    }

    func clearHistory() {
        snapshots = []
        save()
    }

    // MARK: - Fetch
    func refresh() {
        guard hasKey else {
            errorMessage = "Add your DeepSeek API key in Settings."
            return
        }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let key = apiKey
        Task {
            do {
                let snap = try await Self.fetchBalance(key: key)
                self.append(snap)
                self.isAvailable = true
                self.lastFetch = Date()
            } catch {
                self.errorMessage = (error as? DSError)?.message ?? error.localizedDescription
            }
            self.isLoading = false
        }
    }

    private func append(_ snap: BalanceSnapshot) {
        // Avoid duplicate near-identical points within the same minute.
        if let last = snapshots.last,
           abs(last.date.timeIntervalSince(snap.date)) < 30,
           last.total == snap.total {
            return
        }
        snapshots.append(snap)
        save()
    }

    struct DSError: Error { let message: String }

    nonisolated static func fetchBalance(key: String) async throws -> BalanceSnapshot {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            throw DSError(message: "Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw DSError(message: "No HTTP response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw DSError(message: "Invalid API key (401).") }
            throw DSError(message: "DeepSeek API error \(http.statusCode).")
        }
        let decoded = try JSONDecoder().decode(BalanceResponse.self, from: data)
        guard let info = decoded.balance_infos.first else {
            throw DSError(message: "No balance info returned.")
        }
        return BalanceSnapshot(
            date: Date(),
            currency: info.currency,
            total: Double(info.total_balance) ?? 0,
            granted: Double(info.granted_balance) ?? 0,
            toppedUp: Double(info.topped_up_balance) ?? 0)
    }
}

func formatMoney(_ v: Double, currency: String) -> String {
    let symbol = currency == "USD" ? "$" : (currency == "CNY" ? "¥" : "")
    return symbol + String(format: "%.2f", v) + (symbol.isEmpty ? " \(currency)" : "")
}
