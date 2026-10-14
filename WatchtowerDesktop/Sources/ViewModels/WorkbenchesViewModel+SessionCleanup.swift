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
///
/// Plans run in tasks the center owns and applies in tasks this view model
/// owns (`cleanupRuns`), so leaving the page cancels neither.
extension WorkbenchesViewModel {
    /// The Delete dialog opened on a workbench session: plans its cleanup,
    /// as the delete will run it — after its terminal is closed. A
    /// standalone terminal has nothing to clean up. Cancelling the caller
    /// leaves the plan running.
    func planCleanupBeforeDelete(_ session: TerminalSession) async {
        guard let workbenchID = session.projectID, let center = sessionCleanup else { return }
        await center.startPlan(sessionID: session.id, workbenchID: workbenchID, closingSession: true).value
    }

    /// The Clean Up… sheet opened: plans with every live terminal passed,
    /// this session's included (its worktree is kept while it runs).
    /// Cancelling the caller leaves the plan running.
    func planCleanupForSheet(_ session: TerminalSession) async {
        guard let workbenchID = session.projectID, let center = sessionCleanup else { return }
        await center.startPlan(sessionID: session.id, workbenchID: workbenchID).value
    }

    /// The Delete dialog's phase for `session`; idle without a center.
    func deleteCleanupPhase(_ session: TerminalSession) -> SessionCleanupPhase {
        sessionCleanup?.cleanupPhase(for: .session(session.id)) ?? .idle
    }

    /// What the Delete dialog shows for `session`; nil until a plan is
    /// ready.
    func deleteCleanupChoice(_ session: TerminalSession) -> SessionDeleteCleanupChoice? {
        guard case let .ready(plan) = deleteCleanupPhase(session) else { return nil }
        return SessionDeleteCleanupChoice(plan: plan)
    }

    /// The dialog went away without Delete and Clean Up.
    func dismissDeleteCleanup(_ session: TerminalSession) {
        guard !cleaningUpSessions.contains(session.id) else { return }
        sessionCleanup?.forgetCleanup(.session(session.id))
    }

    /// **Delete and Clean Up**: see `startDeleteAndCleanUp`; true when the
    /// row was deleted.
    @discardableResult
    func deleteAndCleanUp(_ session: TerminalSession, choice: SessionDeleteCleanupChoice?) async -> Bool {
        await startDeleteAndCleanUp(session, choice: choice).value
    }

    /// Starts **Delete and Clean Up** in a run this view model owns: marks
    /// the row busy, closes the terminal, applies exactly the keys `choice`
    /// (what the dialog showed) still finds removable, then deletes the row
    /// through the deferred delete (PROJ-17) and tells the page about any
    /// shown item Go kept. A failed cleanup keeps the row and puts the
    /// failure on the page (PROJ-18); the run's value is false then. With
    /// nothing shown it is a plain delete; on a row already busy, nothing.
    @discardableResult
    func startDeleteAndCleanUp(_ session: TerminalSession, choice: SessionDeleteCleanupChoice?) -> Task<Bool, Never> {
        guard !cleaningUpSessions.contains(session.id) else { return Task { false } }
        guard let choice, choice.offersCleanup, let workbenchID = session.projectID, let center = sessionCleanup else {
            return Task {
                await self.delete(session)
                return true
            }
        }
        cleaningUpSessions.insert(session.id)
        let run = Task {
            await self.runDeleteAndCleanUp(session, workbenchID: workbenchID, center: center, choice: choice)
        }
        cleanupRuns[session.id] = run
        return run
    }

    private func runDeleteAndCleanUp(
        _ session: TerminalSession, workbenchID: Int64, center: SessionCleanupCenter, choice: SessionDeleteCleanupChoice
    ) async -> Bool {
        let scope = SessionCleanupScope.session(session.id)
        setSessionError(nil, projectID: workbenchID)
        await terminalCenter?.close(sessionID: session.id)
        forgetProcessState(session.id)
        var keys = choice.removable.map(\.key)
        var final: SessionCleanupPlan?
        if choice.needsReplan {
            // The terminal is closed: what it kept may be removable now.
            await center.planCleanup(sessionID: session.id, workbenchID: workbenchID, closingSession: true)
            guard case let .ready(replan) = center.cleanupPhase(for: scope) else {
                return await keepAfterFailedCleanup(session, workbenchID: workbenchID, center: center)
            }
            keys = choice.keysToApply(after: replan)
            final = replan
        }
        if !keys.isEmpty {
            guard await center.applyCleanup(sessionID: session.id, workbenchID: workbenchID, items: keys) else {
                return await keepAfterFailedCleanup(session, workbenchID: workbenchID, center: center)
            }
            if case let .done(result) = center.cleanupPhase(for: scope) { final = result }
        }
        let kept = final.map(choice.keptItems(in:)) ?? []
        center.forgetCleanup(scope)
        endCleanupRun(session.id)
        await delete(session)
        if let notice = SessionCleanupPresentation.keptAfterDeleteNotice(title: session.title, kept: kept) {
            setSessionError(notice, projectID: workbenchID)
        }
        return true
    }

    private func keepAfterFailedCleanup(
        _ session: TerminalSession, workbenchID: Int64, center: SessionCleanupCenter
    ) async -> Bool {
        let reason = center.failureText(for: .session(session.id)) ?? "unknown error"
        endCleanupRun(session.id)
        setSessionError("Cleanup failed, so “\(session.title)” was kept: \(reason)", projectID: workbenchID)
        await loadCleanupRecord(sessionID: session.id)
        return false
    }

    private func endCleanupRun(_ sessionID: Int64) {
        cleaningUpSessions.remove(sessionID)
        cleanupRuns[sessionID] = nil
    }

    // MARK: Clean Up… sheet

    /// The sheet's ticked items it would remove: pending removals of the
    /// ready plan among `ticked`; empty in any other phase.
    func sheetCleanupChoice(_ session: TerminalSession, ticked: Set<String>) -> [SessionCleanupItem] {
        guard case let .ready(plan) = deleteCleanupPhase(session) else { return [] }
        return plan.items.filter { ticked.contains($0.key) && $0.isPendingRemoval }
    }

    /// The sheet's **Clean Up**: applies exactly the ticked pending
    /// removals in a run this view model owns, then reloads the report's
    /// Cleanup line. Ending while the sheet is closed, it puts a failure on
    /// the page and forgets the phase; with the sheet open, the sheet shows
    /// the result. True when nothing failed.
    @discardableResult
    func applySheetCleanup(_ session: TerminalSession, ticked: Set<String>) async -> Bool {
        let keys = sheetCleanupChoice(session, ticked: ticked).map(\.key)
        guard let workbenchID = session.projectID, let center = sessionCleanup,
              !keys.isEmpty, cleanupRuns[session.id] == nil else { return false }
        let run = Task {
            let ok = await center.applyCleanup(sessionID: session.id, workbenchID: workbenchID, items: keys)
            await self.finishSheetCleanup(session, workbenchID: workbenchID, center: center, ok: ok)
            return ok
        }
        cleanupRuns[session.id] = run
        return await run.value
    }

    private func finishSheetCleanup(
        _ session: TerminalSession, workbenchID: Int64, center: SessionCleanupCenter, ok: Bool
    ) async {
        cleanupRuns[session.id] = nil
        await loadCleanupRecord(sessionID: session.id)
        guard !openCleanupSheets.contains(session.id) else { return }
        let scope = SessionCleanupScope.session(session.id)
        if !ok {
            let reason = center.failureText(for: scope) ?? "unknown error"
            setSessionError("Cleanup of “\(session.title)” failed: \(reason)", projectID: workbenchID)
        }
        center.forgetCleanup(scope)
    }

    /// The sheet came on screen.
    func cleanupSheetAppeared(_ session: TerminalSession) {
        openCleanupSheets.insert(session.id)
    }

    /// The sheet left the screen (closed, or torn down with the page). An
    /// apply still running reports and forgets when it ends.
    func cleanupSheetDisappeared(_ session: TerminalSession) {
        openCleanupSheets.remove(session.id)
    }

    /// The sheet's Cancel, Done or Close: forgets its plan or result. An
    /// apply still running is kept (it forgets when it ends, the sheet then
    /// being gone).
    func closeCleanupSheet(_ session: TerminalSession) {
        openCleanupSheets.remove(session.id)
        guard cleanupRuns[session.id] == nil else { return }
        sessionCleanup?.forgetCleanup(.session(session.id))
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
