import SwiftUI
import Charts

struct CopilotDashboardView: View {
    @ObservedObject var store: CopilotStore

    private let cols = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                // Stat tiles
                LazyVGrid(columns: cols, spacing: 14) {
                    StatTile(title: "Total Tokens",
                             value: formatTokens(store.totalTokens),
                             subtitle: formatFull(store.totalTokens) + " all-time",
                             systemImage: "sum", tint: Theme.primary)
                    StatTile(title: "Today",
                             value: formatTokens(store.tokensToday),
                             subtitle: "since midnight",
                             systemImage: "sun.max.fill", tint: Theme.accent)
                    StatTile(title: "This Hour",
                             value: formatTokens(store.tokensThisHour),
                             subtitle: "current hour",
                             systemImage: "clock.fill", tint: Theme.sky)
                    StatTile(title: "Premium Requests",
                             value: formatPremium(store.premiumUnits),
                             subtitle: "\(store.premiumRequests) model requests",
                             systemImage: "bolt.fill", tint: Theme.primaryDark)
                }

                if store.records.isEmpty {
                    HintBox(icon: "doc.text.magnifyingglass",
                            title: store.isScanning ? "Scanning sessions…" : "No usage found yet",
                            message: "Reading GitHub Copilot CLI sessions from \(store.logsRoot.path). Use Copilot CLI, then press Refresh.")
                } else {
                    perDayChart
                    perHourChart
                    HStack(alignment: .top, spacing: 14) {
                        sessionsCard
                        rightColumn
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.background)
    }

    // MARK: Header
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Copilot Usage")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(action: { store.refresh() }) {
                HStack(spacing: 6) {
                    if store.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.primary)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.isScanning)
        }
    }

    private var statusLine: String {
        var parts: [String] = ["\(store.fileCount) sessions"]
        if let last = store.lastScan {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            parts.append("updated \(f.string(from: last))")
        }
        if let err = store.errorMessage { parts = [err] }
        return parts.joined(separator: " · ")
    }

    // MARK: Per-day chart
    private var perDayChart: some View {
        let data = store.perDay(days: 30)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Tokens per Day (last 30 days)", systemImage: "calendar")
                Chart(data) { b in
                    BarMark(
                        x: .value("Day", b.id, unit: .day),
                        y: .value("Tokens", b.total)
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.accent, Theme.primary],
                                       startPoint: .top, endPoint: .bottom)
                    )
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
                .frame(height: 220)
            }
        }
    }

    // MARK: Per-hour chart
    private var perHourChart: some View {
        let data = store.perHour(hours: 24)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Tokens per Hour (last 24 hours)", systemImage: "clock")
                Chart(data) { b in
                    AreaMark(
                        x: .value("Hour", b.id),
                        y: .value("Tokens", b.total)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.sky.opacity(0.55), Theme.sky.opacity(0.05)],
                                       startPoint: .top, endPoint: .bottom))
                    LineMark(
                        x: .value("Hour", b.id),
                        y: .value("Tokens", b.total)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYAxis { AxisMarks { v in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel { if let n = v.as(Int.self) { Text(formatTokens(n)) } }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel(format: .dateTime.hour())
                } }
                .frame(height: 200)
            }
        }
    }

    // MARK: Sessions list
    private var sessionsCard: some View {
        let sessions = store.sessions(limit: 12)
        let maxT = sessions.map(\.total).max() ?? 1
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Tokens per Session", systemImage: "list.bullet.rectangle")
                ForEach(sessions) { s in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(s.project.isEmpty ? "session" : s.project)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(String(s.id.prefix(8)))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(formatTokens(s.total))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.primary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.background)
                                Capsule().fill(
                                    LinearGradient(colors: [Theme.accent, Theme.primary],
                                                   startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(4, geo.size.width * CGFloat(s.total) / CGFloat(maxT)))
                            }
                        }
                        .frame(height: 7)
                        HStack(spacing: 10) {
                            Text("\(s.messages) msgs")
                            Text("in \(formatTokens(s.input))")
                            Text("out \(formatTokens(s.output))")
                            Spacer()
                            Text(relativeTime(s.lastActivity))
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Right column (breakdown + models)
    private var rightColumn: some View {
        VStack(spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Token Breakdown", systemImage: "chart.pie.fill")
                    StatRow(label: "Input", value: formatFull(store.totalInput))
                    StatRow(label: "Output", value: formatFull(store.totalOutput), color: Theme.accent)
                    StatRow(label: "Cache write", value: formatFull(store.totalCacheCreate))
                    StatRow(label: "Cache read", value: formatFull(store.totalCacheRead), color: Theme.textSecondary)
                    Divider()
                    StatRow(label: "Total", value: formatFull(store.totalTokens), color: Theme.primary)
                    if store.premiumRequests > 0 {
                        StatRow(label: "Premium requests",
                                value: formatPremium(store.premiumUnits) + " units",
                                color: Theme.primaryDark)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "By Model", systemImage: "cpu")
                    let models = store.models()
                    let total = max(1, models.reduce(0) { $0 + $1.total })
                    ForEach(Array(models.prefix(6).enumerated()), id: \.element.id) { idx, m in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(Theme.series[idx % Theme.series.count])
                                    .frame(width: 8, height: 8)
                                Text(m.id).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                                Text(formatTokens(m.total))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            GeometryReader { geo in
                                Capsule().fill(Theme.series[idx % Theme.series.count].opacity(0.85))
                                    .frame(width: max(3, geo.size.width * CGFloat(m.total) / CGFloat(total)))
                            }.frame(height: 5)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 320)
    }

    private func relativeTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    /// Premium request units are fractional (e.g. 0.25× / 1× model multipliers).
    private func formatPremium(_ v: Double) -> String {
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%.2f", v)
    }
}
