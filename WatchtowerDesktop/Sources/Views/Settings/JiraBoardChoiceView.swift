import SwiftUI
import GRDB
import WatchtowerCore

/// The add-site sheet's second step (#572): Jira syncs only the boards picked
/// here, and a new site's boards arrive unselected. Fetches the board list of
/// the site the connect added (every enabled site when it added none —
/// `JiraBoardPicker.sites`) with `jira --account N boards`, lists them with
/// the current selection checked (grouped by site when there are several),
/// and on Done writes only the changes through `jira boards select|deselect`.
/// Skip leaves everything as it is; the Boards tab and the Jira tabs' empty
/// states keep the Choose Jira boards action. No foreground sync and no
/// daemon restart here: the sheet's `JiraAccountsViewModel.finishBoardStep`
/// wires the daemon once, and the daemon syncs the chosen boards (and starts
/// the site's history backfill) on its own path.
///
/// With `connectConfluence` (#573, the connect asked for Confluence too) the
/// step also selects the new site's recent Confluence spaces once, in the
/// background, and shows one line naming them — not a step of its own.
struct JiraBoardChoiceView: View {
    @Environment(AppState.self) private var appState

    /// Account ids read before the connect; nil lists every enabled site.
    let accountIDsBefore: Set<Int>?
    /// The connect also requested Confluence (`--with-confluence`).
    var connectConfluence = false
    /// Done (after its writes) or Skip.
    let onClose: () -> Void

    /// The Confluence line (`ConfluenceConnectStep.summary`); nil while the
    /// selection runs or when Confluence was not asked for.
    @State private var confluenceLine: String?

    @State private var sites: [JiraAccount] = []
    @State private var boards: [JiraBoard] = []
    @State private var chosen: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false
    /// A site's board fetch failed (or the read did): with nothing listed
    /// the step says it couldn't load, not that the site has no boards.
    @State private var loadFailed = false
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

            if let confluenceLine {
                Text(confluenceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

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
                Button("Skip", action: onClose)
                    .disabled(isSaving)
                Button("Done") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || isSaving)
            }
        }
        .task { await load() }
        .task {
            if connectConfluence { await selectConfluenceSpaces() }
        }
    }

    /// Selects the added site's recent Confluence spaces (once per sheet),
    /// then names what is selected. The CLI checks the grant, so a consent
    /// that left Confluence out reports its hint here.
    private func selectConfluenceSpaces() async {
        guard let pool = appState.databaseManager?.dbPool, let cliPath = Constants.findCLIPath() else {
            confluenceLine = ConfluenceConnectStep.summary(spaceNames: [], failures: ["Watchtower CLI not found"])
            return
        }
        do {
            let accounts = try await pool.read { db in try JiraAccountQueries.fetchAll(db) }
            let added = ConfluenceConnectStep.addedSites(accounts, before: accountIDsBefore)
            guard !added.isEmpty else {
                confluenceLine = ConfluenceConnectStep.summary(siteFound: false, spaceNames: [], failures: [])
                return
            }
            var failures: [String] = []
            for site in added {
                if let failure = await JiraBoardsCLI.run(
                    cliPath: cliPath,
                    arguments: ConfluenceConnectStep.selectArgs(accountID: site.id),
                    fallbackMessage: "failed to choose spaces"
                ) {
                    failures.append(failure)
                }
            }
            let names = try await pool.read { db in
                try added.flatMap { try ExtSourceQueries.fetchForJiraAccount(db, accountID: Int64($0.id)) }
                    .map(\.containerName)
            }
            confluenceLine = ConfluenceConnectStep.summary(spaceNames: names, failures: failures)
        } catch {
            confluenceLine = ConfluenceConnectStep.summary(spaceNames: [], failures: [error.localizedDescription])
        }
    }

    @ViewBuilder
    private var list: some View {
        if isLoading {
            Text("Loading boards…")
                .foregroundStyle(.secondary)
        } else if boards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(loadFailed ? "Couldn't load boards." : "No boards found on this site.")
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await load() } }
            }
        } else if sites.count > 1 {
            List {
                ForEach(sites) { site in
                    let siteBoards = boards.filter { Int($0.accountID) == site.id }
                    if !siteBoards.isEmpty {
                        Section(site.displayName) {
                            ForEach(siteBoards, id: \.rowID, content: row)
                        }
                    }
                }
            }
            .listStyle(.bordered)
        } else {
            List(boards, id: \.rowID, rowContent: row)
                .listStyle(.bordered)
        }
    }

    private func row(_ board: JiraBoard) -> some View {
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

    private func binding(for board: JiraBoard) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(board.rowID) },
            set: { isOn in
                if isOn { chosen.insert(board.rowID) } else { chosen.remove(board.rowID) }
            }
        )
    }

    /// Fetches the listed sites' boards from Jira, then reads them back.
    /// A failed fetch still lists what the database already has.
    private func load() async {
        isLoading = true
        error = nil
        loadFailed = false
        defer { isLoading = false }
        guard let pool = appState.databaseManager?.dbPool else {
            error = "Database not available"
            loadFailed = true
            return
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            loadFailed = true
            return
        }
        do {
            let accounts = try await pool.read { db in try JiraAccountQueries.fetchAll(db) }
            sites = JiraBoardPicker.sites(accounts, before: accountIDsBefore)
            var failures: [String] = []
            for call in JiraAccountFanOut.invocations(for: sites, subcommand: ["boards"]) {
                if let failure = await JiraBoardsCLI.run(
                    cliPath: cliPath, arguments: call.arguments, fallbackMessage: "failed to fetch boards"
                ) {
                    failures.append("\(call.account.displayName): \(failure)")
                }
            }
            let all = try await pool.read { db in try JiraQueries.fetchAllBoards(db) }
            boards = JiraBoardPicker.boards(all, of: sites)
            chosen = JiraBoardPicker.selected(boards)
            error = JiraAccountFanOut.failureMessage(failures)
            loadFailed = !failures.isEmpty
        } catch {
            self.error = "Failed to load boards: \(error.localizedDescription)"
            loadFailed = true
        }
    }

    /// Writes the changed selections; on a failure the sheet stays open with
    /// the message, so Done can be pressed again.
    private func save() async {
        let calls = JiraBoardPicker.invocations(for: boards, chosen: chosen)
        guard !calls.isEmpty else {
            onClose()
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
        onClose()
    }
}
