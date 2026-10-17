import SwiftUI
import GRDB
import WatchtowerCore

/// The add-site sheet's second step (#572): Jira syncs only the boards picked
/// here, and a new site's boards arrive unselected. Fetches the board list of
/// every enabled site (`jira --account N boards`), lists them with the current
/// selection checked, and on Done writes only the changes through
/// `jira boards select|deselect`. Skip leaves everything as it is; the Boards
/// tab and the Jira tabs' empty states keep the Choose Jira boards action.
/// No foreground sync: the daemon syncs the chosen boards (and starts the
/// site's history backfill) on its own path.
struct JiraBoardChoiceView: View {
    @Environment(AppState.self) private var appState

    /// `changed`: Done wrote a new selection (the daemon should re-wire).
    let onDone: (_ changed: Bool) -> Void

    @State private var boards: [JiraBoard] = []
    @State private var chosen: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Boards")
                .font(.title2)
                .fontWeight(.bold)
            Text("Watchtower syncs issues only from the boards you pick. You can change this later in Boards.")
                .font(.caption)
                .foregroundStyle(.secondary)

            list
                .frame(maxHeight: .infinity)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if isLoading || isSaving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Skip") { onDone(false) }
                    .disabled(isSaving)
                Button("Done") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || isSaving)
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var list: some View {
        if isLoading {
            Text("Loading boards…")
                .foregroundStyle(.secondary)
        } else if boards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No boards found on this site.")
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await load() } }
            }
        } else {
            List(boards, id: \.rowID) { board in
                Toggle(isOn: binding(for: board)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(board.name)
                        Text(board.projectKey)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.bordered)
        }
    }

    private func binding(for board: JiraBoard) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(board.rowID) },
            set: { isOn in
                if isOn { chosen.insert(board.rowID) } else { chosen.remove(board.rowID) }
            }
        )
    }

    /// Fetches every enabled site's boards from Jira, then reads them back.
    /// A failed fetch still lists what the database already has.
    private func load() async {
        guard let pool = appState.databaseManager?.dbPool else {
            error = "Database not available"
            isLoading = false
            return
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        do {
            let accounts = try await pool.read { db in try JiraAccountQueries.fetchAll(db) }
            var failures: [String] = []
            for call in JiraAccountFanOut.invocations(for: accounts, subcommand: ["boards"]) {
                if let failure = await JiraBoardsCLI.run(
                    cliPath: cliPath, arguments: call.arguments, fallbackMessage: "failed to fetch boards"
                ) {
                    failures.append("\(call.account.displayName): \(failure)")
                }
            }
            let all = try await pool.read { db in try JiraQueries.fetchAllBoards(db) }
            boards = JiraBoardPicker.boards(all, of: accounts)
            chosen = JiraBoardPicker.selected(boards)
            error = JiraAccountFanOut.failureMessage(failures)
        } catch {
            self.error = "Failed to load boards: \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Writes the changed selections; on a failure the sheet stays open with
    /// the message, so Done can be pressed again.
    private func save() async {
        let calls = JiraBoardPicker.invocations(for: boards, chosen: chosen)
        guard !calls.isEmpty else {
            onDone(false)
            return
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }
        isSaving = true
        error = nil
        var failures: [String] = []
        for arguments in calls {
            if let failure = await JiraBoardsCLI.run(
                cliPath: cliPath, arguments: arguments, fallbackMessage: "failed to save the board choice"
            ) {
                failures.append(failure)
            }
        }
        isSaving = false
        if let message = JiraAccountFanOut.failureMessage(failures) {
            error = message
            return
        }
        onDone(true)
    }
}
