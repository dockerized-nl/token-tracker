import SwiftUI
import Charts

struct DeepSeekDashboardView: View {
    @ObservedObject var store: DeepSeekStore

    private let cols = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !store.hasKey {
                    HintBox(icon: "key.fill",
                            title: "Connect DeepSeek",
                            message: "Add your DeepSeek API key in Settings to track remaining credit and usage.")
                } else {
                    LazyVGrid(columns: cols, spacing: 14) {
                        StatTile(title: "Credit Left",
                                 value: store.latest.map { formatMoney($0.total, currency: $0.currency) } ?? "—",
                                 subtitle: store.isAvailable ? "available now" : "account unavailable",
                                 systemImage: "creditcard.fill",
                                 tint: creditTint)
                        StatTile(title: "Credit Used",
                                 value: formatMoney(store.creditUsed, currency: store.currency),
                                 subtitle: "since tracking began",
                                 systemImage: "arrow.down.right.circle.fill",
                                 tint: Theme.accent)
                        StatTile(title: "Used Today",
                                 value: formatMoney(store.creditUsedToday, currency: store.currency),
                                 subtitle: "since midnight",
                                 systemImage: "sun.max.fill",
                                 tint: Theme.sky)
                        StatTile(title: "Topped Up",
                                 value: store.latest.map { formatMoney($0.toppedUp, currency: $0.currency) } ?? "—",
                                 subtitle: store.latest.map { "granted " + formatMoney($0.granted, currency: $0.currency) } ?? "",
                                 systemImage: "plus.circle.fill",
                                 tint: Theme.primaryDark)
                    }

                    if store.snapshots.count < 2 {
                        HintBox(icon: "chart.line.uptrend.xyaxis",
                                title: "Building usage history",
                                message: "Refresh periodically (or keep the app open) to chart how your DeepSeek credit is consumed over time.")
                    } else {
                        balanceChart
                        usageChart
                    }
                    compositionCard
                }
            }
            .padding(22)
        }
        .background(Theme.background)
    }

    private var creditTint: Color {
        guard let t = store.latest?.total else { return Theme.primary }
        if t <= 1 { return Theme.bad }
        if t <= 5 { return Theme.warn }
        return Theme.good
    }

    // MARK: Header
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("DeepSeek Usage")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(store.errorMessage == nil ? Theme.textSecondary : Theme.bad)
            }
            Spacer()
            Button(action: { store.refresh() }) {
                HStack(spacing: 6) {
                    if store.isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text("Refresh")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.primary)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading || !store.hasKey)
        }
    }

    private var statusLine: String {
        if let err = store.errorMessage { return err }
        var parts: [String] = ["\(store.snapshots.count) snapshots"]
        if let last = store.lastFetch {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            parts.append("updated \(f.string(from: last))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Balance over time
    private var balanceChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Credit Balance Over Time", systemImage: "chart.line.downtrend.xyaxis")
                Chart(store.snapshots) { s in
                    AreaMark(x: .value("Time", s.date), y: .value("Balance", s.total))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Theme.primary.opacity(0.4), Theme.primary.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", s.date), y: .value("Balance", s.total))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYAxis { AxisMarks { v in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(formatMoney(d, currency: store.currency)) } }
                } }
                .frame(height: 220)
            }
        }
    }

    // MARK: Usage per day (derived from snapshot deltas)
    private var usageChart: some View {
        let buckets = dailyUsage()
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Credit Used per Day", systemImage: "calendar")
                if buckets.isEmpty {
                    Text("Not enough history yet.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    Chart(buckets, id: \.day) { b in
                        BarMark(x: .value("Day", b.day, unit: .day),
                                y: .value("Used", b.used))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.primary],
                                                        startPoint: .top, endPoint: .bottom))
                        .cornerRadius(3)
                    }
                    .chartYAxis { AxisMarks { v in
                        AxisGridLine().foregroundStyle(Theme.cardStroke)
                        AxisValueLabel { if let d = v.as(Double.self) { Text(formatMoney(d, currency: store.currency)) } }
                    } }
                    .frame(height: 180)
                }
            }
        }
    }

    private struct DayUse { let day: Date; let used: Double }
    private func dailyUsage() -> [DayUse] {
        let cal = Calendar.current
        var byDay: [Date: (first: BalanceSnapshot, last: BalanceSnapshot)] = [:]
        for s in store.snapshots {
            let day = cal.startOfDay(for: s.date)
            if var e = byDay[day] {
                if s.date < e.first.date { e.first = s }
                if s.date > e.last.date { e.last = s }
                byDay[day] = e
            } else {
                byDay[day] = (s, s)
            }
        }
        return byDay.keys.sorted().map { day in
            let e = byDay[day]!
            return DayUse(day: day, used: max(0, e.first.total - e.last.total))
        }
    }

    // MARK: Composition
    private var compositionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Balance Composition", systemImage: "chart.pie.fill")
                if let s = store.latest {
                    StatRow(label: "Granted credit", value: formatMoney(s.granted, currency: s.currency))
                    StatRow(label: "Topped-up credit", value: formatMoney(s.toppedUp, currency: s.currency), color: Theme.accent)
                    Divider()
                    StatRow(label: "Total available", value: formatMoney(s.total, currency: s.currency), color: Theme.primary)
                    StatRow(label: "Account status",
                            value: store.isAvailable ? "Available" : "Unavailable",
                            color: store.isAvailable ? Theme.good : Theme.bad)
                } else {
                    Text("No data yet — press Refresh.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
