import SwiftUI
import GRDB
import WatchtowerCore

struct JiraSyncInfoView: View {
    @Environment(AppState.self) private var appState
    @State private var lastSyncTime: String?
    @State private var issueCount: Int = 0
    @State private var isSyncing: Bool = false
    @State private var syncError: String?
    @State private var observationTask: Task<Void, Never>?

    var body: some View {
        Section("Sync") {
            LabeledContent("Last sync") {
                if let syncTime = lastSyncTime,
                   !syncTime.isEmpty {
                    Text(relativeSyncTime(syncTime))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Issues synced") {
                Text("\(issueCount)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    runSync()
                } label: {
                    HStack(spacing: 4) {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(
                            isSyncing
                                ? "Syncing..."
                                : "Sync Now"
                        )
                    }
                }
                .disabled(isSyncing)

                if let err = syncError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .onAppear { startObserving() }
        .onDisappear { observationTask?.cancel() }
    }

    private func relativeSyncTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        guard let date = formatter.date(from: isoString)
                ?? ISO8601DateFormatter().date(
                    from: isoString
                ) else {
            return isoString
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// `jira sync` is account-scoped — a bare call fails with "multiple Jira
    /// sites connected — pass --account <id>" once a second site is enabled —
    /// so this syncs each enabled account in turn (the boards-refresh shape)
    /// and reports whichever sites failed.
    private func runSync() {
        guard let cliPath = Constants.findCLIPath() else {
            syncError = "Watchtower CLI not found"
            return
        }
        guard let db = appState.databaseManager else {
            syncError = "Database not available"
            return
        }

        isSyncing = true
        syncError = nil
        let dbPool = db.dbPool

        Task.detached {
            let calls: [(account: JiraAccount, arguments: [String])]
            do {
                let all = try await dbPool.read { db in try JiraAccountQueries.fetchAll(db) }
                calls = JiraAccountFanOut.invocations(for: all, subcommand: ["sync"])
            } catch {
                await MainActor.run {
                    isSyncing = false
                    syncError = "Failed to load Jira accounts: \(error.localizedDescription)"
                }
                return
            }
            guard !calls.isEmpty else {
                await MainActor.run {
                    isSyncing = false
                    syncError = "No connected Jira sites"
                }
                return
            }

            var failures: [String] = []
            for call in calls {
                if let failure = await JiraBoardsCLI.run(
                    cliPath: cliPath,
                    arguments: call.arguments,
                    fallbackMessage: "sync failed"
                ) {
                    failures.append("\(call.account.displayName): \(failure)")
                }
            }

            let message = JiraAccountFanOut.failureMessage(failures)
            await MainActor.run {
                isSyncing = false
                syncError = message
            }
        }
    }

    private func startObserving() {
        guard let db = appState.databaseManager else { return }
        loadSyncInfo(db: db)
        let dbPool = db.dbPool
        observationTask = Task {
            let observation = ValueObservation.tracking { db in
                (
                    lastSync: try JiraQueries.fetchLastSyncTime(db),
                    count: try JiraQueries.fetchIssueCount(db)
                )
            }
            do {
                for try await info in observation.values(
                    in: dbPool
                ).dropFirst() {
                    guard !Task.isCancelled else { break }
                    self.lastSyncTime = info.lastSync
                    self.issueCount = info.count
                }
            } catch {}
        }
    }

    private func loadSyncInfo(db: DatabaseManager) {
        Task {
            let result = try? await db.dbPool.read { db in
                (
                    lastSync: try JiraQueries.fetchLastSyncTime(db),
                    count: try JiraQueries.fetchIssueCount(db)
                )
            }
            if let result {
                lastSyncTime = result.lastSync
                issueCount = result.count
            }
        }
    }
}
