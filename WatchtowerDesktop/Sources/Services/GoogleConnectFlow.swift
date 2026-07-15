import Foundation

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

    var fullyConnected: Bool { calendar.isConnected && gmail.isConnected }

    /// At least one still-disconnected service is selected.
    var hasSelection: Bool {
        (includeCalendar && !calendar.isConnected) || (includeGmail && !gmail.isConnected)
    }

    /// Re-stat the token files (cheap) so views can refresh on appear.
    func refresh() {
        calendar.checkStatus()
        gmail.checkStatus()
    }

    /// Runs `watchtower google login` with flags for the selected services
    /// that are still missing — one browser consent for the whole selection.
    func connect() {
        guard !isRunning, hasSelection else { return }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        // --app-return: the success page redirects to watchtower-auth:// so
        // macOS brings the app back to the foreground after the browser step.
        var args = ["google", "login", "--app-return"]
        let wantCalendar = includeCalendar && !calendar.isConnected
        let wantGmail = includeGmail && !gmail.isConnected
        if wantCalendar { args.append("--calendar") }
        if wantGmail { args.append("--gmail") }

        isRunning = true
        error = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        loginProcess = process

        Task.detached {
            let result = await Self.runProcess(process)
            await MainActor.run {
                self.loginProcess = nil
                self.finishConnect(
                    exitCode: result.exitCode,
                    stderr: result.stderr,
                    wantCalendar: wantCalendar,
                    wantGmail: wantGmail
                )
            }
        }
    }

    func cancel() {
        if let process = loginProcess, process.isRunning {
            process.terminate()
        }
        loginProcess = nil
        isRunning = false
    }

    private func finishConnect(exitCode: Int32, stderr: String, wantCalendar: Bool, wantGmail: Bool) {
        refresh()
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
