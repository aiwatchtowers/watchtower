import SwiftUI
import GRDB
import WatchtowerCore

struct StatusBarView: View {
    @Environment(AppState.self) private var appState
    @State private var daemonManager = DaemonManager()
    @State private var lastSync: String?
    @State private var stats: WorkspaceStats?
    @State private var backfillLine: String?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 16) {
            // Daemon status
            HStack(spacing: 4) {
                Circle()
                    .fill(daemonManager.isRunning ? .green : .gray)
                    .frame(width: 6, height: 6)
                Text(daemonManager.isRunning ? "Daemon running" : "Daemon stopped")
            }

            Divider().frame(height: 12)

            // Last sync (click to open Usage)
            Group {
                if let lastSync {
                    Text("Synced \(TimeFormatting.relativeTime(from: lastSync))")
                } else {
                    Text("Never synced")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                appState.selectedDestination = .usage
            }

            if let backfillLine {
                Text(backfillLine)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Stats
            if let stats {
                HStack(spacing: 12) {
                    Label("\(stats.channelCount)", systemImage: "number")
                    Label("\(stats.userCount)", systemImage: "person.2")
                    Label(formatNumber(stats.messageCount), systemImage: "message")
                }
            }

            Divider().frame(height: 12)

            Text("v\(Constants.appVersion)")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            daemonManager.resolvePathIfNeeded()
            daemonManager.startPolling()
            loadStats()
            refreshTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    loadStats()
                }
            }
        }
        .onDisappear {
            daemonManager.stopPolling()
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private func loadStats() {
        guard let db = appState.databaseManager else { return }
        Task.detached {
            do {
                let (ws, st) = try await db.dbPool.read { db in
                    (try WorkspaceQueries.fetchWorkspace(db), try WorkspaceStats.fetch(db))
                }
                await MainActor.run {
                    lastSync = ws?.syncedAt
                    stats = st
                }
            } catch {
                // Status bar stats are decorative: a failed read keeps the last shown values.
                NSLog("StatusBarView: failed to load stats: %@", error.localizedDescription)
            }
            // Its own read, so a missing history_backfill table cannot blank
            // the stats; a failed read keeps the last line.
            do {
                let line = try await db.dbPool.read { BackfillProgress.line(try BackfillQueries.rows($0)) }
                await MainActor.run { backfillLine = line }
            } catch {
                NSLog("StatusBarView: failed to load backfill line: %@", error.localizedDescription)
            }
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
