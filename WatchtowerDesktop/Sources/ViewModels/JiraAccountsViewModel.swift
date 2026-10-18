import Foundation
import GRDB
import WatchtowerCore

/// Drives the multi-site Jira connections shown in Settings → Jira and the
/// add-site sheet. Each row is a DB-backed `jira_accounts` record — any number
/// of Atlassian sites side by side, each independently granting access via its
/// own OAuth consent flow and carrying its own token file. Owned by AppState
/// so the accounts list and any in-flight connect survive navigating away from
/// Settings. Deliberate structural copy of `SlackAccountsViewModel` (house
/// pattern) — `jira add`/`jira login` are browser-consent flows like
/// `slack add`/`slack login`, both passing `--app-return` so the CLI opens
/// watchtower-auth:// and macOS brings the app back to the foreground when
/// consent finishes.
@MainActor
@Observable
final class JiraAccountsViewModel {
    private(set) var accounts: [JiraAccount] = []
    var isConnecting = false
    var error: String?

    /// The restart the last successful account change kicked off under
    /// `.restart` (nil under `.deferred`) — held so tests can await it.
    @ObservationIgnored private(set) var daemonRestartTask: Task<Void, Never>?
    /// The policy a connect held for its board step (`addAccountHoldingRestart`).
    @ObservationIgnored private var heldRestart: DaemonRestartPolicy?
    /// The sheet closed (`finishBoardStep`) while its connect was still
    /// running: a connect that succeeds afterwards applies its policy at
    /// once, since no one is left to release a held restart.
    @ObservationIgnored private var boardStepClosed = false
    /// The last browser flow ended in a user Cancel (SIGTERM/SIGKILL).
    @ObservationIgnored private var lastAuthFlowCancelled = false
    /// The last browser flow timed out (`jira add`'s stable exit code).
    @ObservationIgnored private var lastAuthFlowTimedOut = false
    /// The running consent's stdout so far (`noteAuthOutput`).
    @ObservationIgnored private var authOutput = Data()
    /// A status line for the running consent, e.g. the Jira-only retry
    /// (#573); nil otherwise.
    private(set) var connectStatus: String?
    /// The sites `jira add` offers while it waits for the owner's choice — a
    /// grant that reaches several Atlassian sites (#574); nil otherwise.
    private(set) var siteChoices: [JiraSiteChoice]?
    /// The running `jira add`'s stdin, where `chooseSite` writes the answer.
    @ObservationIgnored private var siteAnswerPipe: Pipe?
    /// The running flow's site list was cancelled (`declineSiteChoice`).
    @ObservationIgnored private var siteChoiceDeclined = false

    private let dbPool: DatabasePool
    private let daemon: any DaemonRestarting
    /// Resolves the CLI binary; injectable so tests can run a stand-in.
    private let cliPath: () -> String?
    private var authProcess: Process?

    init(
        dbPool: DatabasePool,
        daemon: any DaemonRestarting = LiveDaemonRestarter(),
        cliPath: @escaping () -> String? = Constants.findCLIPath
    ) {
        self.dbPool = dbPool
        self.daemon = daemon
        self.cliPath = cliPath
    }

    // MARK: - Refresh

    /// Called after every successful reload — every account change this VM
    /// makes ends in one. Injected by AppState, which re-resolves the owner
    /// identity here (OWNER-01; the CatchUp `onRecapsChanged` precedent).
    var onAccountsChanged: (() async -> Void)?

    /// Cross-process writes (the CLI subprocess, or the daemon's Jira syncers)
    /// don't fire GRDB's ValueObservation, so callers reload on appear / after
    /// a CLI call completes rather than observing live.
    func refresh() {
        Task { await refreshAsync() }
    }

    /// The awaitable body of `refresh()`, split out so tests can call it
    /// directly and observe `accounts` deterministically instead of racing a
    /// detached `Task`.
    func refreshAsync() async {
        do {
            let rows = try await dbPool.read { db in try JiraAccountQueries.fetchAll(db) }
            self.accounts = rows
            await onAccountsChanged?()
        } catch {
            self.error = "Failed to load accounts: \(error.localizedDescription)"
        }
    }

    // MARK: - Add

    /// Builds the `jira add` args. No `--label`: the CLI names the site after
    /// its host (`db.JiraAccountLabel`); the owner renames it in Settings.
    /// Pure and side-effect-free so the flag assembly is directly testable
    /// without shelling out to a real process.
    ///
    /// No site is asked up front (#574): `--app-site-picker` makes a grant
    /// that reaches several Atlassian sites print them as one line
    /// (`JiraSitePrompt`), and the sheet answers with the one the owner picks.
    ///
    /// `withConfluence` adds `--with-confluence` (#573): the same Atlassian
    /// consent also grants Confluence read access, so the site's Confluence
    /// needs no second sign-in.
    /// The add sheet's "Also connect Confluence" starts checked (#573, the
    /// owner's ask): unticking it is the opt-out.
    static let alsoConnectConfluenceByDefault = true

    static func addArgs(withConfluence: Bool = false) -> [String] {
        var args = ["jira", "add", "--app-return", "--app-site-picker"]
        if withConfluence {
            args.append("--with-confluence")
        }
        return args
    }

    /// Connects a new Atlassian site via `watchtower jira add`. The OAuth
    /// consent happens in the loopback browser; the detached Process is held in
    /// `authProcess` so `cancelConnect()` can terminate it mid-flow.
    /// Returns false when a Cancel ended the flow (`runAuthFlow`).
    @discardableResult
    func addAccount(withConfluence: Bool = false, daemonPolicy: DaemonRestartPolicy = .restart) async -> Bool {
        await runAuthFlow(
            args: Self.addArgs(withConfluence: withConfluence),
            failurePrefix: "Connect failed",
            daemonPolicy: daemonPolicy,
            picksSite: true
        )
    }

    /// Answers the running `jira add`'s site question with the owner's pick
    /// from `siteChoices`; the connect then carries on as usual.
    func chooseSite(_ site: JiraSiteChoice) {
        guard siteChoices?.contains(site) == true, let pipe = siteAnswerPipe else { return }
        siteChoices = nil
        siteAnswerPipe = nil
        ProcessPipes.feed(pipe, JiraSitePrompt.answer(site))
    }

    /// Cancel on the site list (#574 review F1): closes `jira add`'s stdin
    /// instead of killing it. The CLI reads end-of-file, chooses no site and
    /// exits before any account row exists; the flow ends as a Cancel.
    func declineSiteChoice() {
        guard siteChoices != nil, let pipe = siteAnswerPipe else { return }
        siteChoices = nil
        siteAnswerPipe = nil
        siteChoiceDeclined = true
        try? pipe.fileHandleForWriting.close()
    }

    /// The add sheet went away mid-connect (#574 review F2): a pending site
    /// question is declined first, then the flow is cancelled, so no
    /// `jira add` outlives its sheet and a reopened sheet starts afresh.
    func abandonConnect() {
        declineSiteChoice()
        if isConnecting { cancelConnect() }
    }

    /// The add sheet's connect (#572): `addAccount` with the daemon restart
    /// held while the board step is up, so the new site and its chosen
    /// boards are wired in by one restart (`finishBoardStep`), not two
    /// overlapping ones. If the sheet already went away, the policy applies
    /// as soon as the connect succeeds. Also reads the account ids before
    /// the connect, so the board step can list the site it added (nil when
    /// that read fails).
    func addAccountHoldingRestart(
        withConfluence: Bool = false, daemonPolicy: DaemonRestartPolicy
    ) async -> (connected: Bool, accountIDsBefore: Set<Int>?, cancelled: Bool, timedOut: Bool) {
        boardStepClosed = false
        heldRestart = nil
        let before = try? await dbPool.read { db in Set(try JiraAccountQueries.fetchAll(db).map(\.id)) }
        guard await addAccount(withConfluence: withConfluence, daemonPolicy: .deferred) else {
            return (false, before, true, false)
        }
        guard error == nil, !lastAuthFlowCancelled else {
            return (false, before, lastAuthFlowCancelled, lastAuthFlowTimedOut)
        }
        if boardStepClosed {
            daemonRestartTask = daemonPolicy.apply(using: daemon)
        } else {
            heldRestart = daemonPolicy
        }
        return (true, before, false, false)
    }

    /// The board step closed (Done, Skip or the sheet went away): applies the
    /// connect's held policy once — a restart under `.restart`, nothing under
    /// onboarding's `.deferred` (the daemon starts at the finish). With the
    /// connect still running, it marks the step closed so the connect applies
    /// the policy itself. A second call does nothing.
    func finishBoardStep() {
        guard let policy = heldRestart else {
            boardStepClosed = true
            return
        }
        heldRestart = nil
        daemonRestartTask = policy.apply(using: daemon)
    }

    // MARK: - Re-login

    /// Builds the `jira login` args for re-consenting an existing account.
    /// Pure and side-effect-free. `withConfluence` adds `--with-confluence`
    /// (the Confluence scopes, opt-in on the CLI side). The default Re-login
    /// omits the flag; the CLI itself keeps the Confluence scopes when the
    /// account already uses Confluence (`jiraReloginOptions`, cmd/jira.go).
    /// `withConfluenceWrite` adds `--with-confluence-write` (the write scopes
    /// for page editing; the CLI treats it as implying `--with-confluence`).
    static func loginArgs(accountID: Int, withConfluence: Bool = false, withConfluenceWrite: Bool = false) -> [String] {
        var args = ["jira", "login", "--account", String(accountID), "--app-return"]
        if withConfluenceWrite {
            args.append("--with-confluence-write")
        } else if withConfluence {
            args.append("--with-confluence")
        }
        return args
    }

    static func loginArgs(for account: JiraAccount) -> [String] {
        loginArgs(accountID: account.id)
    }

    /// Re-consents `account` via `watchtower jira login --account <id>` — same
    /// OAuth loopback-browser flow shape as `addAccount`, used when an
    /// account's status is "error"/"revoked" and needs a fresh grant.
    func relogin(_ account: JiraAccount) async {
        await runAuthFlow(args: Self.loginArgs(for: account), failurePrefix: "Re-login failed", daemonPolicy: .restart)
    }

    /// Settings → Jira → Confluence "Grant Confluence access": the same
    /// re-consent flow with `--with-confluence`, so the new grant carries the
    /// Confluence scopes.
    func reloginWithConfluence(accountID: Int) async {
        await runAuthFlow(
            args: Self.loginArgs(accountID: accountID, withConfluence: true),
            failurePrefix: "Granting Confluence access failed",
            daemonPolicy: .restart
        )
    }

    /// Settings → Jira → Confluence "Allow editing": the same re-consent flow
    /// with `--with-confluence-write`, so the new grant also carries the
    /// Confluence write scopes the assistant's page edits need.
    func reloginWithConfluenceWrite(accountID: Int) async {
        await runAuthFlow(
            args: Self.loginArgs(accountID: accountID, withConfluenceWrite: true),
            failurePrefix: "Allowing Confluence editing failed",
            daemonPolicy: .restart
        )
    }

    func cancelConnect() {
        lastAuthFlowCancelled = true
        if let process = authProcess, process.isRunning {
            process.terminate()
        }
        authProcess = nil
        isConnecting = false
        connectStatus = nil
        siteChoices = nil
    }

    // MARK: - Enable / Disable

    /// Builds the CLI args to enable or disable `account` — `jira enable <id>`
    /// or `jira disable <id>`. Pure and side-effect-free.
    static func setEnabledArgs(for account: JiraAccount, enabled: Bool) -> [String] {
        ["jira", enabled ? "enable" : "disable", String(account.id)]
    }

    /// Enables or disables `account` via `watchtower jira enable|disable <id>`.
    /// A disabled account stops syncing but keeps all its already-synced data.
    func setEnabled(_ account: JiraAccount, enabled: Bool) async {
        await runManagementCommand(
            args: Self.setEnabledArgs(for: account, enabled: enabled),
            failurePrefix: enabled ? "Enable failed" : "Disable failed",
            daemonPolicy: .restart
        )
    }

    // MARK: - Rename

    /// Renames account `accountID` via `watchtower jira rename` (`AccountRename`). No
    /// daemon restart: the daemon reads labels when it needs them.
    func rename(accountID: Int, to name: String) async {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return
        }
        error = await AccountRename.run(source: "jira", id: accountID, name: name, cliPath: cliPath())
        if error == nil { await refreshAsync() }
    }

    // MARK: - Remove

    /// Builds the CLI args to disconnect `account` — `jira remove <id>`.
    /// Pure and side-effect-free so the dispatch is directly testable without
    /// shelling out to a real process.
    static func removeArgs(for account: JiraAccount) -> [String] {
        ["jira", "remove", String(account.id)]
    }

    /// Removes `account` via `watchtower jira remove <id>`. Non-destructive:
    /// the CLI deletes the token file and marks the row removed/disabled but
    /// keeps already-synced issues, boards, and releases.
    func remove(_ account: JiraAccount, daemonPolicy: DaemonRestartPolicy = .restart) async {
        await runManagementCommand(
            args: Self.removeArgs(for: account),
            failurePrefix: "Remove failed",
            daemonPolicy: daemonPolicy
        )
    }

    // MARK: - Flow helpers

    /// Browser-consent flow (`add`/`login`) — holds the detached Process in
    /// `authProcess` so `cancelConnect()` can terminate it while this awaits.
    /// `picksSite` (`jira add` only) wires a stdin pipe for the site question
    /// (#574); a re-login never asks one, and must not wait on a stdin.
    ///
    /// Returns false when `cancelConnect` ended this flow. Its state was
    /// reset by the Cancel, and a newer flow may already own it, so the
    /// ended one touches nothing after its process exits.
    @discardableResult
    private func runAuthFlow(
        args: [String], failurePrefix: String, daemonPolicy: DaemonRestartPolicy, picksSite: Bool = false
    ) async -> Bool {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return true
        }
        guard let cliPath = cliPath() else {
            error = "Watchtower CLI not found"
            return true
        }

        isConnecting = true
        error = nil
        lastAuthFlowCancelled = false
        lastAuthFlowTimedOut = false
        siteChoiceDeclined = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process

        // The login environment is awaited with the flow already shown as
        // running (Cancel visible); a Cancel or a newer attempt meanwhile
        // drops this launch.
        process.environment = await Constants.resolvedEnvironmentAsync()
        guard authProcess === process else { return false }

        connectStatus = nil
        authOutput = Data()
        siteChoices = nil
        let answerPipe = picksSite ? Pipe() : nil
        if let answerPipe { process.standardInput = answerPipe }
        siteAnswerPipe = answerPipe
        let onStdout: @Sendable (Data) -> Void = { [weak self] chunk in
            Task { @MainActor in self?.noteAuthOutput(chunk, of: process) }
        }
        // A Cancel that landed while the launch was under way found nothing
        // running to terminate: stop the child as soon as it exists.
        let onLaunch: @Sendable (Process) -> Void = { [weak self] launched in
            Task { @MainActor in
                if self?.authProcess !== launched { launched.terminate() }
            }
        }
        let result = await ProcessPipes.run(process, onLaunch: onLaunch, onStdout: onStdout).trimmed
        // Never answered (one site, a failure, a Cancel): release the pipe.
        if let answerPipe {
            if siteAnswerPipe === answerPipe { siteAnswerPipe = nil }
            try? answerPipe.fileHandleForWriting.close()
        }
        guard authProcess === process else {
            // It may still have finished before the Cancel landed.
            if result.exitCode == 0 { refresh() }
            return false
        }
        authProcess = nil
        isConnecting = false
        connectStatus = nil
        siteChoices = nil
        if siteChoiceDeclined {
            // The owner cancelled at the site list: the CLI's "no site was
            // chosen" exit is that Cancel, not an error to show.
            lastAuthFlowCancelled = true
            error = nil
            return true
        }
        applyResult(result, failurePrefix: failurePrefix, daemonPolicy: daemonPolicy)
        return true
    }

    /// Live stdout of the running consent: the Jira-only retry's marker
    /// (#573) turns into the sheet's status line.
    /// Chunks are kept as bytes: one may end inside a multi-byte character.
    private func noteAuthOutput(_ chunk: Data, of process: Process) {
        guard authProcess === process else { return }
        authOutput.append(chunk)
        let output = String(bytes: authOutput, encoding: .utf8) ?? ""
        if ConfluenceConnectStep.isRetryingJiraOnly(output) {
            connectStatus = ConfluenceConnectStep.retryStatus
        }
        // The site question (#574), shown once while its answer is pending.
        if siteChoices == nil, siteAnswerPipe != nil, let sites = JiraSitePrompt.sites(in: output) {
            siteChoices = sites
        }
    }

    /// Non-browser management command (`enable`/`disable`/`remove`) — a plain
    /// awaited CLI invocation, no `authProcess` to cancel.
    private func runManagementCommand(
        args: [String],
        failurePrefix: String,
        daemonPolicy: DaemonRestartPolicy
    ) async {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return
        }
        guard let cliPath = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isConnecting = true
        error = nil

        let result = await Self.runCLI(path: cliPath, arguments: args)
        isConnecting = false
        applyResult(result, failurePrefix: failurePrefix, daemonPolicy: daemonPolicy)
    }

    private func applyResult(
        _ result: (exitCode: Int32, stdout: String, stderr: String),
        failurePrefix: String,
        daemonPolicy: DaemonRestartPolicy
    ) {
        if result.exitCode == 15 || result.exitCode == 9 { lastAuthFlowCancelled = true }
        lastAuthFlowTimedOut = result.exitCode == ConfluenceConnectStep.loginTimedOutExitCode
        if result.exitCode == 0 {
            error = nil
            refresh()
            // Re-wire the daemon so the account set change takes effect now
            // (unless onboarding defers it — `DaemonRestartPolicy`).
            daemonRestartTask = daemonPolicy.apply(using: daemon)
        } else if result.exitCode == 15 || result.exitCode == 9 {
            // SIGTERM/SIGKILL — user cancelled
            error = nil
        } else {
            error = result.stderr.isEmpty
                ? "\(failurePrefix) (exit \(result.exitCode))"
                : String(result.stderr.prefix(200))
        }
    }

    // MARK: - CLI Helpers

    nonisolated private static func runCLI(
        path: String,
        arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = await Constants.resolvedEnvironmentAsync()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        return await runProcess(process)
    }

    /// Runs a pre-configured Process, draining stdout and stderr concurrently
    /// (`ProcessPipes`, SB3) so neither stream can wedge the other.
    nonisolated private static func runProcess(
        _ process: Process
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await ProcessPipes.run(process).trimmed
    }
}
