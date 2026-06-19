import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case deepseek = "DeepSeek"
    case settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .claude:   return "sparkles"
        case .codex:    return "chevron.left.forwardslash.chevron.right"
        case .deepseek: return "magnifyingglass.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

@main
struct TokenTrackerApp: App {
    @StateObject private var claude = ClaudeStore()
    @StateObject private var codex = CodexStore()
    @StateObject private var deepseek = DeepSeekStore()

    var body: some Scene {
        WindowGroup {
            RootView(claude: claude, codex: codex, deepseek: deepseek)
                .frame(minWidth: 920, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

struct RootView: View {
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var codex: CodexStore
    @ObservedObject var deepseek: DeepSeekStore
    @State private var selection: Section = .claude
    @AppStorage("refreshInterval") private var refreshInterval: Int = 30
    @State private var timer: Timer?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch selection {
            case .claude:   ClaudeDashboardView(store: claude)
            case .codex:    CodexDashboardView(store: codex)
            case .deepseek: DeepSeekDashboardView(store: deepseek)
            case .settings: SettingsView(claude: claude, codex: codex, deepseek: deepseek)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            claude.refresh()
            codex.refresh()
            if deepseek.hasKey { deepseek.refresh() }
            startTimer()
        }
        .onChange(of: refreshInterval) { _, _ in startTimer() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent, Theme.primary],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 34, height: 34)
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(.white).font(.system(size: 15, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Token Tracker").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("usage dashboard").font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)

            ForEach(Section.allCases) { item in
                Button(action: { selection = item }) {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .frame(width: 18)
                            .foregroundStyle(selection == item ? .white : Theme.primary)
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selection == item ? .white : Theme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selection == item ? Theme.primary : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
            footer
        }
        .frame(minWidth: 210)
        .background(Theme.sidebar)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if selection == .claude || selection == .settings {
                Label(formatTokens(claude.totalTokens) + " Claude", systemImage: "sum")
            }
            if selection == .codex || selection == .settings {
                Label(formatTokens(codex.totalTokens) + " Codex", systemImage: "sum")
            }
            if (selection == .deepseek || selection == .settings), let s = deepseek.latest {
                Label(formatMoney(s.total, currency: s.currency) + " left", systemImage: "creditcard")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private func startTimer() {
        timer?.invalidate()
        guard refreshInterval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(refreshInterval), repeats: true) { _ in
            Task { @MainActor in
                claude.refresh()
                codex.refresh()
                if deepseek.hasKey { deepseek.refresh() }
            }
        }
    }
}
