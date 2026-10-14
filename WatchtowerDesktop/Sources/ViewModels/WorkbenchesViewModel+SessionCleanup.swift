import Foundation
import GRDB
import WatchtowerCore

/// Session cleanup on the Workbench page (board #535, spec
/// 2026-10-12-session-cleanup §12, PROJ-18), driven through
/// `SessionCleanupCenter`.
///
/// **Delete and Clean Up** composes with the deferred delete (PROJ-17): the
/// terminal closes, the cleanup applies the keys the dialog showed, and
/// only once it succeeded does the row go the normal way — hidden at once,
/// its DELETE after the Undo window. Undo then brings the row back, never
/// the removed worktrees and branches. A failed cleanup deletes nothing:
/// the row stays, with the failure on the page, for a retry or Delete Only.
/// The quick ✕ / ⌘⌫ delete never cleans up (it is Delete Only).
extension WorkbenchesViewModel {
    /// The Delete dialog opened on a workbench session: plans its cleanup,
    /// as the delete will run it — after its terminal is closed. A
    /// standalone terminal has nothing to clean up.
    func planCleanupBeforeDelete(_ session: TerminalSession) async {
        guard let workbenchID = session.projectID, let center = sessionCleanup else { return }
        await center.planCleanup(sessionID: session.id, workbenchID: workbenchID, closingSession: true)
    }

    /// The Clean Up… sheet opened: plans with every live terminal passed,
    /// this session's included (its worktree is kept while it runs).
    func planCleanupForSheet(_ session: TerminalSession) async {
        guard let workbenchID = session.projectID, let center = sessionCleanup else { return }
        await center.planCleanup(sessionID: session.id, workbenchID: workbenchID)
    }

    /// The Clean Up… sheet's Clean Up: applies the ticked keys, then reloads
    /// the report's Cleanup line.
    func applySheetCleanup(_ session: TerminalSession, items: [String]) async {
        guard let workbenchID = session.projectID, let center = sessionCleanup else { return }
        _ = await center.applyCleanup(sessionID: session.id, workbenchID: workbenchID, items: items)
        await loadCleanupRecord(sessionID: session.id)
    }

    /// The Delete dialog's phase for `session`; idle without a center.
    func deleteCleanupPhase(_ session: TerminalSession) -> SessionCleanupPhase {
        sessionCleanup?.cleanupPhase(for: .session(session.id)) ?? .idle
    }

    /// The dialog went away without Delete and Clean Up.
    func dismissDeleteCleanup(_ session: TerminalSession) {
        sessionCleanup?.forgetCleanup(.session(session.id))
    }

    /// The planned `remove` keys the Delete dialog shows for `session` —
    /// what Delete and Clean Up passes on; empty until a plan is ready.
    func plannedDeleteRemovals(_ session: TerminalSession) -> [String] {
        sessionCleanup?.plannedRemovals(for: .session(session.id)) ?? []
    }

    /// **Delete and Clean Up**: closes the terminal, applies exactly `items`
    /// (the planned `remove` keys the dialog showed), then deletes the row
    /// through the deferred delete (PROJ-17). A failed cleanup keeps the row
    /// and puts the failure on the page (PROJ-18); false then. With no item
    /// it is a plain delete.
    @discardableResult
    func deleteAndCleanUp(_ session: TerminalSession, items keys: [String]) async -> Bool {
        guard let workbenchID = session.projectID, let center = sessionCleanup, !keys.isEmpty else {
            await delete(session)
            return true
        }
        setSessionError(nil, projectID: workbenchID)
        await terminalCenter?.close(sessionID: session.id)
        forgetProcessState(session.id)
        guard await center.applyCleanup(sessionID: session.id, workbenchID: workbenchID, items: keys) else {
            let reason = center.failureText(for: .session(session.id)) ?? "unknown error"
            setSessionError("Cleanup failed, so “\(session.title)” was kept: \(reason)", projectID: workbenchID)
            await loadCleanupRecord(sessionID: session.id)
            return false
        }
        await delete(session)
        return true
    }

    // MARK: Report line

    /// Reads session `sessionID`'s stored cleanup result. A failed read is
    /// logged and keeps the last value.
    func loadCleanupRecord(sessionID: Int64) async {
        do {
            let record = try await dbPool.read { try TerminalSessionQueries.fetchCleanupRecord($0, sessionID: sessionID) }
            cleanupRecords[sessionID] = record
        } catch {
            NSLog("WorkbenchesViewModel: reading session %lld's cleanup result failed: %@",
                  sessionID, error.localizedDescription)
        }
    }

    /// The report's Cleanup line: Go's summary, or "Cleanup ran — result
    /// unreadable"; nil when the session has no cleanup result.
    func cleanupReportLine(sessionID: Int64) -> String? {
        cleanupRecords[sessionID].flatMap(SessionCleanupPresentation.reportLine)
    }
}
