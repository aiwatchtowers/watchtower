import Foundation
import GRDB
import WatchtowerCore

/// Drives the combined Google connect: the user picks services via pre-checked
/// checkboxes (Google's own consent screen cannot pre-select scopes), then ONE
/// OAuth flow requests exactly the selected scopes — a single consent screen
/// listing precisely the access being granted. On success the matching sync
/// flags are enabled in config so the daemon actually syncs. A partial grant
/// (one checkbox left unticked on Google's screen) connects only the approved
/// service. Shared by the Calendar tab's connect screen and the Inbox banner.
@MainActor
@Observable
final class GoogleConnectFlow {
    /// One instance for the whole app: the Calendar tab and the Inbox banner
    /// must share the same `isRunning` latch, otherwise each surface can
    /// spawn its own login (and its own browser window) in parallel.
    static let shared = GoogleConnectFlow()

    let calendar = GoogleAuthService()
    let gmail = GmailAuthService()

    /// Scope selection shown as pre-checked checkboxes in the connect UI.
    var includeCalendar = true
    var includeGmail = true

    private(set) var isRunning = false
    var error: String?

    private var loginProcess: Process?
    /// Handle to the in-flight `connect()` Task — `cancel()` cancels this
    /// directly, closing the window between `connect()` starting and
    /// `loginProcess` actually being assigned (the account lookup below
    /// awaits a DB read before any process exists to terminate). Without
    /// this, a cancel() during that window found nothing to terminate, reset
    /// `isRunning` anyway, and let the in-flight Task launch the OAuth
    /// subprocess completely uncancellably — worse, the reset `isRunning`
    /// let a second `connect()` start a second, PARALLEL OAuth flow (N1).
    private var connectTask: Task<Void, Never>?
    private var dbPool: DatabasePool?

    var fullyConnected: Bool { calendar.isConnected && gmail.isConnected }

    /// At least one still-disconnected service is selected.
    var hasSelection: Bool {
        (includeCalendar && !calendar.isConnected) || (includeGmail && !gmail.isConnected)
    }

    /// Wires DB access once AppState's pool is available. `shared` is
    /// constructed eagerly (`static let`), before any dbPool exists, so
    /// `calendar`/`gmail`'s DB-derived `isConnected` and `connect()`'s
    /// account lookup stay unavailable until this runs — called once from
    /// `AppState.initGoogleAccounts`, the same point its sibling
    /// `GoogleAccountsViewModel` gets its pool.
    func configure(dbPool: DatabasePool) {
        self.dbPool = dbPool
        calendar.configure(dbPool: dbPool)
        gmail.configure(dbPool: dbPool)
    }

    /// Re-read connection state (cheap DB read) so views can refresh on appear.
    func refresh() {
        calendar.checkStatus()
        gmail.checkStatus()
    }

    /// Builds the `google add`/`google login` args for `connect()` — pure and
    /// side-effect-free so the dispatch is directly testable without shelling
    /// out to a real process or a DB. An empty `accounts` list means this
    /// workspace has no Google account yet, so `google add` creates the first
    /// one outright. Otherwise a tap here widens the oldest surviving
    /// account's scopes via `google login --account <id>` — `accounts[0]`
    /// (ordered by id ASC, see `GoogleAccountQueries.fetchAll`) is that
    /// oldest account, matching the Go-side alias semantics in cmd/google.go's
    /// `resolveAccountOneForLogin`/`disconnectGoogleService`, which also
    /// always operate on the oldest surviving row. Connecting a second,
    /// independent account is a Settings → Google Accounts action
    /// (AddGoogleAccountView / GoogleAccountsViewModel.addAccount), not this flow.
    static func connectArgs(accounts: [GoogleAccount], wantCalendar: Bool, wantGmail: Bool) -> [String] {
        // --app-return: the success page redirects to watchtower-auth:// so
        // macOS brings the app back to the foreground after the browser step.
        var args = accounts.first.map { ["google", "login", "--account", String($0.id), "--app-return"] }
            ?? ["google", "add", "--app-return"]
        if wantCalendar { args.append("--calendar") }
        if wantGmail { args.append("--gmail") }
        return args
    }

    /// Runs `watchtower google add`/`google login` with flags for the
    /// selected services that are still missing — one browser consent for
    /// the whole selection.
    func connect() {
        guard !isRunning, hasSelection else { return }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        let wantCalendar = includeCalendar && !calendar.isConnected
        let wantGmail = includeGmail && !gmail.isConnected

        isRunning = true
        error = nil

        connectTask = Task {
            // cancel() may already have fired before this task body even
            // started running (Task{} only schedules, it doesn't execute
            // inline) — bail before touching the DB or the CLI.
            guard !Task.isCancelled else { return }

            let accounts: [GoogleAccount]
            if let dbPool = self.dbPool {
                accounts = (try? await dbPool.read { db in try GoogleAccountQueries.fetchAll(db) }) ?? []
            } else {
                accounts = []
            }

            // cancel() may also have fired during the DB read above — its
            // only await point before the process launches. Re-check here,
            // before constructing/launching the subprocess: MainActor's
            // serial executor can't interleave a cancel() call between this
            // check and `self.loginProcess = process` right below (no
            // further await in between), so either this sees the
            // cancellation and bails, or cancel() runs strictly after
            // loginProcess is set and terminates the live process instead.
            guard !Task.isCancelled else { return }

            let args = Self.connectArgs(accounts: accounts, wantCalendar: wantCalendar, wantGmail: wantGmail)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = args
            process.environment = Constants.resolvedEnvironment()
            process.currentDirectoryURL = Constants.processWorkingDirectory()
            self.loginProcess = process

            let result = await Self.runProcess(process)
            self.loginProcess = nil
            self.connectTask = nil

            // A cancelled attempt (cancel() already reset isRunning/
            // loginProcess and, if the process had started, terminated it —
            // result here is just that termination's exit code, e.g.
            // SIGTERM) must never reach finishConnect: it writes config
            // (enableSync) and would stomp isRunning back to false a second
            // time on top of whatever a subsequent connect() attempt set it to.
            guard !Task.isCancelled else { return }

            await self.finishConnect(
                exitCode: result.exitCode,
                stderr: result.stderr,
                wantCalendar: wantCalendar,
                wantGmail: wantGmail
            )
        }
    }

    func cancel() {
        // Marks the in-flight Task cancelled FIRST — this is what stops it
        // from ever launching the subprocess if cancel() lands during the
        // pre-launch DB-read window (see connectTask's doc comment above),
        // not the process-termination below, which only covers the case
        // where a process already exists.
        connectTask?.cancel()
        connectTask = nil
        if let process = loginProcess, process.isRunning {
            process.terminate()
        }
        loginProcess = nil
        isRunning = false
    }

    private func finishConnect(exitCode: Int32, stderr: String, wantCalendar: Bool, wantGmail: Bool) async {
        // Await the DB-derived status directly (not the fire-and-forget
        // refresh()) so the enableSync/error decisions below see exactly what
        // the CLI just wrote — trust the DB, no Swift-side flag inference.
        await calendar.checkStatusAsync()
        await gmail.checkStatusAsync()
        if wantCalendar && calendar.isConnected { enableSync(key: \.calendarEnabled) }
        if wantGmail && gmail.isConnected { enableSync(key: \.gmailEnabled) }

        if exitCode == 15 || exitCode == 9 {
            // SIGTERM/SIGKILL — user cancelled
        } else if exitCode != 0 {
            error = stderr.isEmpty ? "Login failed (exit \(exitCode))" : String(stderr.prefix(200))
        } else if (wantCalendar && !calendar.isConnected) || (wantGmail && !gmail.isConnected) {
            // CLI exits 0 on a partial grant — surface what's still missing.
            error = "Some access wasn't granted — approve it on Google's consent screen and retry."
        }
        // On any granted service (even a partial grant), restart the daemon:
        // syncers are wired only at daemon startup, and a restart runs an
        // immediate sync + AI pipeline cycle so data shows up right away.
        if (wantCalendar && calendar.isConnected) || (wantGmail && gmail.isConnected) {
            Task { await DaemonManager.restart() }
        }
        isRunning = false
    }

    /// `ConfigService.calendarEnabled`/`gmailEnabled` are the GLOBAL
    /// daemon-phase sync switches (`cfg.Calendar.Enabled`/`cfg.Gmail.
    /// Enabled`), distinct from any one account's `calendar_enabled`/
    /// `gmail_enabled` column — per the multi-account design, these stay
    /// global toggles, so flipping one on here (once ANY account connects
    /// that service) is still correct. The condition driving the call
    /// (`finishConnect`, above) is now the freshly DB-awaited `isConnected`,
    /// not a separately Swift-inferred flag — no change needed to the body.
    private func enableSync(key: ReferenceWritableKeyPath<ConfigService, Bool>) {
        // Fresh instance: reload the file right before flipping the flag so we
        // don't clobber edits made while the OAuth flow sat in the browser.
        let config = ConfigService()
        config[keyPath: key] = true
        do {
            try config.save()
        } catch {
            self.error = "Failed to save config: \(error.localizedDescription)"
        }
    }

    /// Runs a pre-configured Process, reading pipe data before waitUntilExit to avoid deadlock.
    nonisolated private static func runProcess(
        _ process: Process
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        // Read pipe data BEFORE waitUntilExit to prevent deadlock when output exceeds 64KB
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }
}
