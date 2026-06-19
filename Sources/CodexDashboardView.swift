import SwiftUI
import Charts

struct CodexDashboardView: View {
    @ObservedObject var store: CodexStore
    @ObservedObject var api: CodexAPIStore

    private let cols = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

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
                    StatTile(title: "Sessions",
                             value: "\(store.sessionCount)",
                             subtitle: "\(store.records.count) turns",
                             systemImage: "command", tint: Theme.primaryDark)
                }

                if store.records.isEmpty {
                    HintBox(icon: "chevron.left.forwardslash.chevron.right",
                            title: store.isScanning ? "Scanning Codex sessions…" : "No Codex usage found yet",
                            message: "Reading Codex rollouts from \(store.logsRoot.path). Use Codex, then press Refresh.")
                } else {
                    perDayChart
                    perHourChart
                    HStack(alignment: .top, spacing: 14) {
                        sessionsCard
                        rightColumn
                    }
                }

                APIUsageSection(store: api)
            }
            .padding(22)
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Usage")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(store.errorMessage == nil ? Theme.textSecondary : Theme.bad)
            }
            Spacer()
            Button(action: { store.refresh() }) {
                HStack(spacing: 6) {
                    if store.isScanning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text("Refresh")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.primary).foregroundStyle(.white).clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.isScanning)
        }
    }

    private var statusLine: String {
        if let err = store.errorMessage { return err }
        var parts = ["\(store.fileCount) session files"]
        if let last = store.lastScan {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            parts.append("updated \(f.string(from: last))")
        }
        return parts.joined(separator: " · ")
    }

    private var perDayChart: some View {
        let data = store.perDay(days: 30)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Tokens per Day (last 30 days)", systemImage: "calendar")
                Chart(data) { b in
                    BarMark(x: .value("Day", b.id, unit: .day), y: .value("Tokens", b.total))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.primary],
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
                .frame(height: 220)
            }
        }
    }

    private var perHourChart: some View {
        let data = store.perHour(hours: 24)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Tokens per Hour (last 24 hours)", systemImage: "clock")
                Chart(data) { b in
                    AreaMark(x: .value("Hour", b.id), y: .value("Tokens", b.total))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Theme.sky.opacity(0.55), Theme.sky.opacity(0.05)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Hour", b.id), y: .value("Tokens", b.total))
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

    private var sessionsCard: some View {
        let sessions = store.sessions(limit: 12)
        let maxT = sessions.map(\.total).max() ?? 1
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Tokens per Session", systemImage: "list.bullet.rectangle")
                ForEach(sessions) { s in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(s.project).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text(s.model).font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                            Spacer()
                            Text(formatTokens(s.total)).font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.primary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.background)
                                Capsule().fill(LinearGradient(colors: [Theme.accent, Theme.primary],
                                                              startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(4, geo.size.width * CGFloat(s.total) / CGFloat(maxT)))
                            }
                        }.frame(height: 7)
                        HStack(spacing: 10) {
                            Text("\(s.turns) turns")
                            Text("in \(formatTokens(s.input))")
                            Text("out \(formatTokens(s.output))")
                            Text("reason \(formatTokens(s.reasoning))")
                            Spacer()
                            Text(relativeTime(s.lastActivity))
                        }
                        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var rightColumn: some View {
        VStack(spacing: 14) {
            rateLimitsCard
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Token Breakdown", systemImage: "chart.pie.fill")
                    StatRow(label: "Input", value: formatFull(store.totalInput))
                    StatRow(label: "↳ cached input", value: formatFull(store.totalCachedInput), color: Theme.textSecondary)
                    StatRow(label: "Output", value: formatFull(store.totalOutput), color: Theme.accent)
                    StatRow(label: "↳ reasoning", value: formatFull(store.totalReasoning), color: Theme.textSecondary)
                    Divider()
                    StatRow(label: "Total", value: formatFull(store.totalTokens), color: Theme.primary)
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
                                Circle().fill(Theme.series[idx % Theme.series.count]).frame(width: 8, height: 8)
                                Text(m.id).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                                Text(formatTokens(m.total)).font(.system(size: 12, weight: .semibold))
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

    private var rateLimitsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Rate Limits", systemImage: "gauge.with.dots.needle.50percent")
                if let r = store.latestRate {
                    rateBar(title: "Primary", subtitle: windowLabel(r.primaryWindowMinutes),
                            percent: r.primaryPercent, reset: r.primaryResetsAt)
                    rateBar(title: "Secondary", subtitle: windowLabel(r.secondaryWindowMinutes),
                            percent: r.secondaryPercent, reset: r.secondaryResetsAt)
                    if let bal = r.creditsBalance {
                        Divider()
                        StatRow(label: "Credits balance", value: String(format: "%.2f", bal), color: Theme.primary)
                    }
                    if store.contextWindow > 0 {
                        StatRow(label: "Context window", value: formatFull(store.contextWindow) + " tok",
                                color: Theme.textSecondary)
                    }
                } else {
                    Text("No rate-limit data in logs yet.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func rateBar(title: String, subtitle: String, percent: Double?, reset: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(percent.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(barColor(percent))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.background)
                    Capsule().fill(barColor(percent))
                        .frame(width: max(3, geo.size.width * CGFloat((percent ?? 0) / 100)))
                }
            }.frame(height: 6)
            if let reset {
                Text("resets \(relativeTime(reset))")
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func barColor(_ percent: Double?) -> Color {
        guard let p = percent else { return Theme.sky }
        if p >= 90 { return Theme.bad }
        if p >= 70 { return Theme.warn }
        return Theme.primary
    }

    private func relativeTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}
