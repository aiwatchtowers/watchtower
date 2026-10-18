import Foundation
import WatchtowerCore

extension AppState {
    /// The launch's database steps (#850, spec D5): migrate, then the
    /// compaction step (it needs the schema current and the pool not yet
    /// open; it never fails the launch), then open. Off the concurrency
    /// pool: the migrate child may run for up to 30 s (see ProcessPipes).
    func migrateCompactOpen() async -> Result<DatabaseManager, any Error> {
        await ProcessPipes.offPool { [migrateDatabase] in migrateDatabase() }
        if !quitDuringCompaction {
            let resolveDBPath = compactionDBPathOverride ?? { try DatabaseManager.resolveDBPath() }
            await databaseCompaction.run(resolveDBPath: resolveDBPath)
        }
        return await ProcessPipes.offPool { [openDatabase] in Result { try openDatabase() } }
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
    }

    /// While the launch's compaction step runs (#850, spec D5) every daemon
    /// start, restart and stop-then-start is a no-op: the step stopped the
    /// daemon for `VACUUM`, and the launch's own `ensureDaemonRunning` starts
    /// it once the step ends. A quit that landed before or during the step
    /// keeps them off too. Logs the refused `caller`.
    func daemonStartBlocked(_ caller: String) -> Bool {
        guard databaseCompactionInProgress || quitDuringCompaction else { return false }
        NSLog("[Watchtower] %@ skipped: the database compaction step is running", caller)
        return true
    }

    /// The quit sequence's compaction hook, before it stops the daemon: a
    /// running `--check` or `db compact` child gets SIGTERM so it does not
    /// outlive the app, and the launch neither runs the step nor starts the
    /// daemon afterwards. A no-op once the step has finished.
    func terminateDatabaseCompactionForQuit() {
        guard databaseCompaction.phase != .finished else { return }
        quitDuringCompaction = true
        databaseCompaction.terminateForQuit()
    }
}
