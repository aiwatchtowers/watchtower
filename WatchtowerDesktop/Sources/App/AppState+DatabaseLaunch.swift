import Foundation
import WatchtowerCore

extension DatabaseCompactionStep {
    /// The step over the real CLI and daemon.
    static func production() -> DatabaseCompactionStep {
        DatabaseCompactionStep(
            cli: ProcessCompactionCLI(),
            stopDaemon: { await DaemonManager.stopDaemonBounded() },
            sleep: { try? await Task.sleep(for: $0) },
            log: { NSLog("[Watchtower] %@", $0) }
        )
    }
}

extension AppState {
    /// The launch's database steps (#850, spec D5): migrate, then the
    /// compaction step (it needs the schema current and the pool not yet
    /// open; it never fails the launch), then open. Off the concurrency
    /// pool: the migrate child may run for up to 30 s (see ProcessPipes).
    /// Daemon starts are gated from before the migration to the open.
    func migrateCompactOpen() async -> Result<DatabaseManager, any Error> {
        launchDatabaseStepsRunning = true
        defer { launchDatabaseStepsRunning = false }
        await ProcessPipes.offPool { [migrateDatabase] in migrateDatabase() }
        if !quitDuringCompaction {
            await databaseCompaction.run(resolveDBPath: compactionDBPathOverride ?? Self.resolveCompactionDBPath)
        }
        return await ProcessPipes.offPool { [openDatabase] in Result { try openDatabase() } }
    }

    /// The live database path for the compaction step. No database yet (a
    /// fresh install) is silent; any other resolve error is logged before
    /// the step skips.
    nonisolated static func resolveCompactionDBPath() throws -> String {
        do {
            return try DatabaseManager.resolveDBPath()
        } catch WatchtowerDatabaseError.databaseNotFound {
            throw WatchtowerDatabaseError.databaseNotFound
        } catch {
            NSLog("[Watchtower] DB compaction skipped: %@", error.localizedDescription)
            throw error
        }
    }

    /// The compaction step's daemon stop runs on the start queue, after any
    /// start already running (#850).
    func wireDatabaseCompaction() {
        databaseCompaction.serializeDaemonStop = { [weak self] stop in
            guard let self else { return await stop() }
            await self.enqueueDaemonStart { await stop() }.value
        }
    }

    /// `initialize()` when the database could not be opened: on a fresh
    /// install (no workspace yet) that is onboarding's starting point.
    func handleLaunchDatabaseFailure(_ error: Error) async {
        print("[AppState] database open failed: \(error.localizedDescription)")
        errorMessage = error.localizedDescription
        databaseManager = nil
        if case WatchtowerDatabaseError.ambiguousWorkspace(let names) = error {
            ambiguousWorkspaces = names
        } else {
            ambiguousWorkspaces = []
        }
        // No DB available — if state machine not complete, onboarding needed
        await reconcileOnboarding(dbPool: nil)
        if needsOnboarding {
            // Nothing is connected without a database; only the sidebar of
            // a finished install keeps failing open.
            featureVisibility.connectedSources = .none
        }
        isLoading = false
        restoreDaemonStoppedForCompaction()
    }

    /// A launch that does not reach `ensureDaemonRunning` (the database did
    /// not open) brings the daemon back when onboarding was already complete
    /// and either the compaction step stopped it or a restart was refused
    /// during the steps. A refused restart restarts here, so the daemon reads
    /// the config saved meanwhile; a stop alone only starts. Not after a quit.
    /// A launch that lands in onboarding with a database never had onboarding
    /// complete (`reconcileOnboarding` keeps a complete step), so it needs no
    /// restore.
    func restoreDaemonStoppedForCompaction() {
        let deferredRestart = deferredRestartDuringLaunch
        deferredRestartDuringLaunch = false
        guard databaseCompaction.stoppedDaemon || deferredRestart,
              !needsOnboarding, !quitDuringCompaction else { return }
        NSLog("[Watchtower] bringing back the daemon the launch's database steps held off")
        bringUpDaemonInBackground(startOnly: !deferredRestart)
    }

    /// While the launch's database steps run — from before the migration to
    /// the open, the compaction step included (#850, spec D5) — every daemon
    /// start, restart and stop-then-start is a no-op: the step may stop the
    /// daemon for `VACUUM`, and the launch's own `ensureDaemonRunning` starts
    /// it once the steps end. A refused restart (`restartOnChain`,
    /// `bringUpDaemonInBackground`) is remembered for the restore after a
    /// failed open. A quit that landed before or during the step keeps them
    /// off too. Logs the refused `caller`. The account view models'
    /// `restartLoggingQueued` is exempt: they are built after the database
    /// opens.
    func daemonStartBlocked(_ caller: String) -> Bool {
        guard launchDatabaseStepsRunning || databaseCompactionInProgress || quitDuringCompaction else { return false }
        NSLog("[Watchtower] %@ skipped: the launch's database steps are running", caller)
        if caller == "restartOnChain" || caller == "bringUpDaemonInBackground" {
            deferredRestartDuringLaunch = true
        }
        return true
    }

    /// The quit sequence's compaction hook, before it stops the daemon: a
    /// running `--check` or `db compact` child gets SIGTERM (SIGKILL if it
    /// has not exited after `DatabaseCompactionStep.quitGrace`) so it does
    /// not outlive the app, and the launch neither runs the step nor starts
    /// the daemon afterwards. A no-op once the step has finished.
    func terminateDatabaseCompactionForQuit() async {
        guard databaseCompaction.phase != .finished else { return }
        quitDuringCompaction = true
        await databaseCompaction.terminateForQuit()
    }
}
