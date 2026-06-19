import SwiftUI

struct SettingsView: View {
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var codex: CodexStore
    @ObservedObject var deepseek: DeepSeekStore

    @State private var keyField: String = UserDefaults.standard.string(forKey: "deepseekApiKey") ?? ""
    @State private var pathField: String = UserDefaults.standard.string(forKey: "claudeLogsPath") ?? ""
    @State private var codexPathField: String = UserDefaults.standard.string(forKey: "codexLogsPath") ?? ""
    @AppStorage("refreshInterval") private var refreshInterval: Int = 30
    @State private var savedFlash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                // DeepSeek
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(text: "DeepSeek API", systemImage: "key.fill")
                        Text("Used to read your remaining credit from the DeepSeek balance endpoint. Stored locally on this Mac.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        SecureField("sk-…", text: $keyField)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save & Test") {
                                deepseek.apiKey = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
                                deepseek.refresh()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            if deepseek.isLoading { ProgressView().controlSize(.small) }
                            if let err = deepseek.errorMessage {
                                Text(err).font(.system(size: 11)).foregroundStyle(Theme.bad)
                            } else if deepseek.latest != nil {
                                Label("Connected", systemImage: "checkmark.seal.fill")
                                    .font(.system(size: 11)).foregroundStyle(Theme.good)
                            }
                        }
                        Button("Clear usage history") { deepseek.clearHistory() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }

                // Claude logs
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(text: "Claude Code Logs", systemImage: "folder.fill")
                        Text("Folder scanned for usage. Leave empty to use the default (~/.claude/projects).")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        TextField("~/.claude/projects", text: $pathField)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save & Rescan") {
                                let trimmed = pathField.trimmingCharacters(in: .whitespacesAndNewlines)
                                UserDefaults.standard.set(trimmed, forKey: "claudeLogsPath")
                                claude.refresh()
                                flash()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            Text("Currently: \(claude.logsRoot.path)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }

                // Codex logs
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(text: "Codex Sessions", systemImage: "chevron.left.forwardslash.chevron.right")
                        Text("Folder scanned for Codex usage. Leave empty to use the default (~/.codex/sessions).")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        TextField("~/.codex/sessions", text: $codexPathField)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save & Rescan") {
                                let trimmed = codexPathField.trimmingCharacters(in: .whitespacesAndNewlines)
                                UserDefaults.standard.set(trimmed, forKey: "codexLogsPath")
                                codex.refresh()
                                flash()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            Text("Currently: \(codex.logsRoot.path)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                }

                // Refresh interval
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(text: "Auto-refresh", systemImage: "arrow.clockwise")
                        Picker("Refresh every", selection: $refreshInterval) {
                            Text("Off").tag(0)
                            Text("15 seconds").tag(15)
                            Text("30 seconds").tag(30)
                            Text("1 minute").tag(60)
                            Text("5 minutes").tag(300)
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260)
                        Text("Claude logs and DeepSeek balance refresh automatically on this interval while the app is open.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }

                if savedFlash {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.good).font(.system(size: 12, weight: .semibold))
                }

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: "About", systemImage: "info.circle.fill")
                        Text("Token Tracker — local usage dashboard for Claude, Codex & DeepSeek.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Text("All data stays on your Mac. Nothing is uploaded.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.background)
    }

    private func flash() {
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { savedFlash = false }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(configuration.isPressed ? Theme.primaryDark : Theme.primary)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
