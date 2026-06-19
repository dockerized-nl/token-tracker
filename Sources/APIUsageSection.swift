import SwiftUI
import Charts

/// Billing/usage section embedded inside the Claude and Codex dashboards.
/// Renders cost + token data pulled from a provider's usage/cost reporting API.
struct APIUsageSection<Store: APIUsageStore>: View {
    @ObservedObject var store: Store

    private let cols = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider().padding(.top, 6)
            headerRow

            if !store.hasKey {
                HintBox(icon: "key.fill",
                        title: "Connect \(store.providerTitle)",
                        message: store.settingsHint)
            } else if store.days.isEmpty {
                HintBox(icon: store.isLoading ? "arrow.triangle.2.circlepath" : "chart.bar.doc.horizontal.fill",
                        title: store.isLoading ? "Loading billing data…" : "No billing data yet",
                        message: store.errorMessage
                            ?? "Press Refresh to pull spend and token usage from the API (data can lag a few minutes).")
            } else {
                tiles
                costChart
                tokenChart
                HStack(alignment: .top, spacing: 14) {
                    breakdownCard
                    modelsCard
                }
            }
        }
    }

    // MARK: Header
    private var headerRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(text: "API Usage & Cost (last \(store.windowDays) days)",
                             systemImage: "dollarsign.circle.fill")
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(store.errorMessage == nil ? Theme.textSecondary : Theme.bad)
            }
            Spacer()
            Button(action: { store.refresh() }) {
                HStack(spacing: 6) {
                    if store.isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text("Refresh")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
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
        guard store.hasKey else { return "needs an organization admin key" }
        if let last = store.lastFetch {
            let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"
            return "updated \(f.string(from: last))"
        }
        return "not fetched yet"
    }

    // MARK: Tiles
    private var tiles: some View {
        LazyVGrid(columns: cols, spacing: 14) {
            StatTile(title: "Total Cost",
                     value: formatUSD(store.totalCost),
                     subtitle: "last \(store.windowDays) days",
                     systemImage: "dollarsign.circle.fill", tint: Theme.primary)
            StatTile(title: "Cost Today",
                     value: formatUSD(store.costToday),
                     subtitle: "today (UTC)",
                     systemImage: "sun.max.fill", tint: Theme.accent)
            StatTile(title: "Total Tokens",
                     value: formatTokens(store.totalTokens),
                     subtitle: formatFull(store.totalTokens),
                     systemImage: "sum", tint: Theme.sky)
            StatTile(title: "Tokens Today",
                     value: formatTokens(store.tokensToday),
                     subtitle: "today (UTC)",
                     systemImage: "clock.fill", tint: Theme.primaryDark)
        }
    }

    // MARK: Cost per day
    private var costChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Cost per Day (USD)", systemImage: "calendar")
                Chart(store.days) { d in
                    BarMark(x: .value("Day", d.day, unit: .day),
                            y: .value("Cost", d.costUSD))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.primary],
                                                        startPoint: .top, endPoint: .bottom))
                        .cornerRadius(3)
                }
                .chartYAxis { AxisMarks { v in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel { if let n = v.as(Double.self) { Text(formatUSD(n)) } }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                } }
                .frame(height: 200)
            }
        }
    }

    // MARK: Tokens per day
    private var tokenChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Tokens per Day", systemImage: "chart.bar.fill")
                Chart(store.days) { d in
                    BarMark(x: .value("Day", d.day, unit: .day),
                            y: .value("Tokens", d.totalTokens))
                        .foregroundStyle(LinearGradient(colors: [Theme.sky, Theme.primary],
                                                        startPoint: .top, endPoint: .bottom))
                        .cornerRadius(3)
                }
                .chartYAxis { AxisMarks { v in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel { if let n = v.as(Int.self) { Text(formatTokens(n)) } }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                } }
                .frame(height: 190)
            }
        }
    }

    // MARK: Breakdown
    private var breakdownCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Token Breakdown", systemImage: "chart.pie.fill")
                StatRow(label: "Input (uncached)", value: formatFull(store.totalInput))
                StatRow(label: "Output", value: formatFull(store.totalOutput), color: Theme.accent)
                StatRow(label: "Cache read", value: formatFull(store.totalCacheRead), color: Theme.textSecondary)
                if store.totalCacheWrite > 0 {
                    StatRow(label: "Cache write", value: formatFull(store.totalCacheWrite))
                }
                Divider()
                StatRow(label: "Total tokens", value: formatFull(store.totalTokens), color: Theme.primary)
                StatRow(label: "Total cost", value: formatUSD(store.totalCost), color: Theme.good)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: By model
    private var modelsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "By Model", systemImage: "cpu")
                let models = store.modelTotals
                if models.isEmpty {
                    Text("No per-model data in this window.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    let total = max(1, models.reduce(0) { $0 + $1.totalTokens })
                    ForEach(Array(models.prefix(6).enumerated()), id: \.element.id) { idx, m in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(Theme.series[idx % Theme.series.count])
                                    .frame(width: 8, height: 8)
                                Text(m.model).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                                Text(formatTokens(m.totalTokens))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            GeometryReader { geo in
                                Capsule().fill(Theme.series[idx % Theme.series.count].opacity(0.85))
                                    .frame(width: max(3, geo.size.width * CGFloat(m.totalTokens) / CGFloat(total)))
                            }.frame(height: 5)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 320)
    }
}
