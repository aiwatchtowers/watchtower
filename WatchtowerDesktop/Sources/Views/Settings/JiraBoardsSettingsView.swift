import SwiftUI
import GRDB
import WatchtowerCore

struct JiraBoardsSettingsView: View {
    @Environment(AppState.self) private var appState
    var onSelectBoard: (JiraBoard) -> Void = { _ in }
    @State private var boards: [JiraBoard] = []
    @State private var observationTask: Task<Void, Never>?
    @State private var toggleError: String?

    @State private var isFetching = false
    @State private var reAnalyzingBoardID: Int?
    // TODO: notifiedBoardIDs resets when the view is recreated. Consider @AppStorage or a static Set if persistent dedup is needed.
    @State private var notifiedBoardIDs: Set<Int> = []

    private var syncManager: JiraBoardSyncManager { .shared }

    var body: some View {
        Section("Boards") {
            if boards.isEmpty {
                Text("No boards synced yet")
                    .foregroundStyle(.secondary)
            } else {
                // Keyed on rowID, not id: raw board ids collide across
                // connected sites (migration 00049).
                ForEach(boards, id: \.rowID) { board in
                    boardRow(board)
                }
            }

            Button(action: fetchBoards) {
                HStack(spacing: 6) {
                    if isFetching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(boards.isEmpty ? "Fetch Boards" : "Refresh Boards")
                }
            }
            .disabled(isFetching)

            if let err = toggleError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            startObserving()
            syncManager.onComplete = { [self] in
                if let db = appState.databaseManager {
                    loadBoards(db: db)
                }
            }
        }
        .onDisappear { observationTask?.cancel() }
    }

    private func boardRow(_ board: JiraBoard) -> some View {
        Button { onSelectBoard(board) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(board.name)
                        .fontWeight(.medium)
                    HStack(spacing: 6) {
                        Text(board.projectKey)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(board.boardType)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                boardTypeBadgeColor(board.boardType),
                                in: Capsule()
                            )
                        analyzedBadge(board)
                        if board.isConfigChanged {
                            configChangedBadge
                        }
                    }
                }

                Spacer()

                if board.isConfigChanged {
                    reAnalyzeButton(board)
                }

                if syncManager.syncingBoardID == board.id {
                    syncProgressView
                } else {
                    Text("\(board.issueCount) issues")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "",
                    isOn: Binding(
                        get: { board.isSelected },
                        set: { newValue in
                            toggleBoard(board, selected: newValue)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            checkAndNotifyConfigChange(board)
        }
    }

    // MARK: - Sync Progress

    private var syncProgressView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .trailing, spacing: 1) {
                if let p = syncManager.progress, p.done > 0 {
                    Text("\(p.done) issues")
                        .font(.caption)
                        .monospacedDigit()
                    HStack(spacing: 4) {
                        Text(syncPhaseLabel(p.status))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let elapsed = syncManager.elapsedFormatted {
                            Text(elapsed)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("Starting sync...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func syncPhaseLabel(_ status: String?) -> String {
        switch status {
        case "active": return "Active issues"
        case "active_done": return "Active done"
        case "closed": return "Closed issues"
        case "issues": return "Syncing"
        default: return "Syncing"
        }
    }

    // MARK: - Badges

    @ViewBuilder
    private func analyzedBadge(_ board: JiraBoard) -> some View {
        if !board.llmProfileJSON.isEmpty {
            Text("Analyzed")
                .font(.caption2)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15), in: Capsule())
        } else {
            Text("Not analyzed")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.15), in: Capsule())
        }
    }

    private var configChangedBadge: some View {
        Text("Config changed")
            .font(.caption2)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }

    private func reAnalyzeButton(_ board: JiraBoard) -> some View {
        Button {
            reAnalyzeBoard(board)
        } label: {
            HStack(spacing: 4) {
                if reAnalyzingBoardID == board.id {
                    ProgressView().controlSize(.mini)
                }
                Text("Re-analyze")
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(reAnalyzingBoardID == board.id)
    }

    private func reAnalyzeBoard(_ board: JiraBoard) {
        guard let cliPath = Constants.findCLIPath() else {
            toggleError = "Watchtower CLI not found"
            return
        }

        reAnalyzingBoardID = board.id
        toggleError = nil

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = [
                "jira", "--account", String(board.accountID),
                "boards", "analyze", "--force",
                String(board.id),
            ]
            process.environment = Constants.resolvedEnvironment()
            process.currentDirectoryURL =
                Constants.processWorkingDirectory()

            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    reAnalyzingBoardID = nil
                    toggleError = "Failed to launch CLI"
                }
                return
            }

            let stderrData = stderrPipe.fileHandleForReading
                .readDataToEndOfFile()
            process.waitUntilExit()

            await MainActor.run {
                reAnalyzingBoardID = nil
                if process.terminationStatus != 0 {
                    let stderr = String(
                        data: stderrData, encoding: .utf8
                    )?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? ""
                    toggleError = stderr.isEmpty
                        ? "Re-analysis failed"
                        : String(stderr.prefix(200))
                }
            }
        }
    }

    private func checkAndNotifyConfigChange(_ board: JiraBoard) {
        guard board.isConfigChanged,
              !notifiedBoardIDs.contains(board.id) else { return }
        notifiedBoardIDs.insert(board.id)
        NotificationService.shared
            .sendBoardConfigChangedNotification(boardName: board.name)
    }

    private func boardTypeBadgeColor(
        _ type: String
    ) -> Color {
        switch type {
        case "scrum": return .blue.opacity(0.2)
        case "kanban": return .green.opacity(0.2)
        default: return .gray.opacity(0.2)
        }
    }

    // MARK: - Toggle & Sync

    private func toggleBoard(_ board: JiraBoard, selected: Bool) {
        guard let cliPath = Constants.findCLIPath() else {
            toggleError = "Watchtower CLI not found"
            return
        }

        // Optimistically update local state so the toggle reflects immediately
        if let idx = boards.firstIndex(where: { $0.id == board.id }) {
            boards[idx].isSelected = selected
        }

        toggleError = nil
        let action = selected ? "select" : "deselect"

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = [
                "jira", "--account", String(board.accountID),
                "boards", action, String(board.id)
            ]
            process.environment = Constants.resolvedEnvironment()
            process.currentDirectoryURL =
                Constants.processWorkingDirectory()

            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    toggleError = "Failed to launch CLI"
                }
                return
            }

            let stderrData = stderrPipe.fileHandleForReading
                .readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let stderr = String(
                    data: stderrData, encoding: .utf8
                )?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                await MainActor.run {
                    // Revert optimistic update on failure
                    if let idx = boards.firstIndex(where: { $0.id == board.id }) {
                        boards[idx].isSelected = !selected
                    }
                    toggleError = stderr.isEmpty
                        ? "Failed to \(action) board"
                        : String(stderr.prefix(200))
                }
            } else if selected {
                // Board was enabled — trigger initial sync.
                await MainActor.run {
                    syncManager.startSync(accountID: board.accountID, boardID: board.id)
                }
            }
        }
    }

    // MARK: - Observation

    private func startObserving() {
        guard let db = appState.databaseManager else { return }
        loadBoards(db: db)
        let dbPool = db.dbPool
        observationTask = Task {
            let observation = ValueObservation.tracking { db in
                try JiraQueries.fetchAllBoards(db)
            }
            do {
                for try await newBoards in observation.values(
                    in: dbPool
                ).dropFirst() {
                    guard !Task.isCancelled else { break }
                    self.boards = newBoards
                }
            } catch {}
        }
    }

    private func loadBoards(db: DatabaseManager) {
        Task {
            let result = try? await db.dbPool.read { db in
                try JiraQueries.fetchAllBoards(db)
            }
            if let result {
                boards = result
            }
        }
    }

    /// Refreshes the board list from every connected site. `jira boards` is
    /// account-scoped — without `--account` it errors out as soon as a second
    /// site is connected — so this walks the enabled accounts one at a time and
    /// reports whichever ones failed, leaving the sites that answered refreshed.
    private func fetchBoards() {
        guard let cliPath = Constants.findCLIPath() else {
            toggleError = "Watchtower CLI not found"
            return
        }
        guard let db = appState.databaseManager else {
            toggleError = "Database not available"
            return
        }

        isFetching = true
        toggleError = nil
        let dbPool = db.dbPool

        Task.detached {
            let enabled: [JiraAccount]
            do {
                let all = try await dbPool.read { db in
                    try JiraAccountQueries.fetchAll(db)
                }
                enabled = all.filter(\.enabled)
            } catch {
                await MainActor.run {
                    isFetching = false
                    toggleError = "Failed to load Jira accounts"
                }
                return
            }

            guard !enabled.isEmpty else {
                await MainActor.run {
                    isFetching = false
                    toggleError = "No connected Jira sites"
                }
                return
            }

            var failures: [String] = []
            for account in enabled {
                let failure = JiraBoardsCLI.run(
                    cliPath: cliPath,
                    arguments: [
                        "jira", "--account", String(account.id), "boards"
                    ],
                    fallbackMessage: "failed to fetch boards"
                )
                if let failure {
                    failures.append("\(account.displayName): \(failure)")
                }
            }

            let message = failures.isEmpty
                ? nil
                : String(failures.joined(separator: "; ").prefix(200))
            await MainActor.run {
                isFetching = false
                toggleError = message
            }
        }
    }
}

/// The board screens' CLI seam — every `watchtower jira boards …` call this
/// screen and `JiraBoardProfileView` fire goes through it, so none of them can
/// drop an exit code again.
enum JiraBoardsCLI {
    /// Runs `arguments`, returning nil on success or a user-facing message on
    /// failure (trimmed stderr, else `fallbackMessage`). stderr is drained
    /// before `waitUntilExit` so a chatty failure can't fill the pipe buffer
    /// and deadlock the wait.
    static func run(
        cliPath: String,
        arguments: [String],
        fallbackMessage: String
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return "Failed to launch CLI"
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return nil }
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stderr.isEmpty ? fallbackMessage : String(stderr.prefix(200))
    }
}
