import Foundation
import WatchtowerCore

/// The deferred session delete with its batched Undo (board #480, PROJ-17,
/// spec 2026-10-12-sessions-panel-design §4.2–§4.3).
///
/// One batch, one window: every delete restarts the window from its own
/// moment — the timer is re-armed before the row's process is closed, so a
/// close's kill grace never shortens it — and once the window runs out
/// uncancelled the whole batch commits. The model and the timer agree on
/// the window: `PendingSessionDeletes.deadline` is set at the delete's
/// moment, the timer armed at that same moment sleeps
/// `PendingSessionDeletes.window` and commits only the batch whose deadline
/// it was armed for (`expiredBatch(now: deadline)`); a later delete moved
/// the deadline and cancelled it. A row whose process is still closing is
/// never committed: the window's end then waits for the last close.
extension WorkbenchesViewModel {
    /// Hides the row at once — from the lists, the layout and the
    /// selection — restarts the Undo window, then stops its process; it
    /// writes nothing: the row joins the Undo batch (`pendingDeletes`) and
    /// its DELETE (with its cascades) runs when the window ends or the app
    /// quits (`commitPendingDeletesForQuit`). Claude Code's transcript is
    /// left alone.
    func delete(_ session: TerminalSession) async {
        setSessionError(nil, projectID: session.projectID)
        let at = now()
        pendingDeletes.enqueueSessionDelete(
            .init(sessionID: session.id, workbenchID: session.projectID, title: session.title), now: at
        )
        if let projectID = session.projectID {
            terminalSessions[projectID]?.removeAll { $0.id == session.id }
            forgetInLayout(session.id, projectID: projectID)
        } else {
            standaloneSessions.removeAll { $0.id == session.id }
        }
        if selectedStandaloneID == session.id { selectedStandaloneID = nil }
        armPendingDeleteCommit()
        closingDeletes.insert(session.id)
        await terminalCenter?.close(sessionID: session.id)
        closingDeletes.remove(session.id)
        forgetProcessState(session.id)
        titleAttempts[session.id] = nil
        notYetTitledStreak[session.id] = nil
        await commitIfDueAfterClose()
    }

    /// The toast's text while a batch waits: "Session deleted" / "N
    /// sessions deleted"; nil when nothing is pending.
    var pendingDeleteToast: String? { pendingDeletes.toastText }

    /// Undo: every session of the batch comes back, untouched — its row,
    /// report links and asks were never written. A row comes back not
    /// running (a click or Restart resumes it); the layout is not restored.
    /// A row whose close is still pending comes back too; its close
    /// finishes and commits nothing.
    func undoPendingDeletes() async {
        cancelPendingDeleteWindow()
        let restored = pendingDeletes.restoreBatch()
        for list in Self.sessionLists(of: restored) { await loadSessions(projectID: list) }
    }

    /// Runs the batch's DELETEs in one write. A failed write never keeps a
    /// row hidden: the batch has left `pendingDeletes`, so the reload brings
    /// the rows back, with the error on their list.
    func commitPendingDeletes(_ entries: [PendingSessionDeletes.Entry]) async {
        guard !entries.isEmpty else { return }
        let lists = Self.sessionLists(of: entries)
        do {
            try await startSessionDeletes(entries.map(\.sessionID)).value
        } catch {
            for list in lists {
                setSessionError("Could not delete the session: \(error.localizedDescription)", projectID: list)
            }
        }
        for list in lists { await loadSessions(projectID: list) }
    }

    /// The quit path (`willTerminate`): the batch is committed now, through
    /// the same write as the window's, and the quit waits — bounded by
    /// `quitDeleteWait` in all — for it and for a commit the window's timer
    /// already started. A row still closing is committed too: the quit
    /// closes every terminal anyway. A timeout or an error is logged; the
    /// row then survives and is listed again on the next launch — the safe
    /// side. Whether every write finished within the bound.
    @discardableResult
    func commitPendingDeletesForQuit() -> Bool {
        cancelPendingDeleteWindow()
        let ids = pendingDeletes.takeBatch().map(\.sessionID)
        if !ids.isEmpty { startSessionDeletes(ids) }
        guard deleteWrites.wait(timeout: .now() + quitDeleteWait) == .success else {
            NSLog("WorkbenchesViewModel: deleting sessions on quit timed out; they are listed again next launch")
            return false
        }
        return true
    }

    /// The workbench is gone and its delete cascaded its hidden sessions:
    /// they leave the batch (nothing to commit, nothing to restore).
    func discardPendingDeletes(workbenchID: Int64) {
        pendingDeletes.discardBatch(workbenchID: workbenchID)
        if pendingDeletes.batch.isEmpty { cancelPendingDeleteWindow() }
    }

    /// `rows` without the sessions waiting in the Undo batch.
    func withoutPendingDeletes(_ rows: [TerminalSession]) -> [TerminalSession] {
        let hidden = pendingDeletes.ids
        return hidden.isEmpty ? rows : rows.filter { !hidden.contains($0.id) }
    }

    /// (Re)starts the Undo window for the batch's current deadline.
    private func armPendingDeleteCommit() {
        cancelPendingDeleteWindow()
        guard let deadline = pendingDeletes.deadline else { return }
        deleteCommitTask = Task { [weak self] in
            guard let sleep = self?.deleteSleep else { return }
            await sleep(.seconds(PendingSessionDeletes.window))
            guard let self, !Task.isCancelled else { return }
            await pendingDeleteWindowEnded(armedFor: deadline)
        }
    }

    private func cancelPendingDeleteWindow() {
        deleteCommitTask?.cancel()
        deleteCommitTask = nil
        deleteCommitDue = false
    }

    /// The window armed for `deadline` ran out: the batch commits, unless a
    /// later delete moved the deadline or one of its rows is still closing
    /// (then the last close commits it, `commitIfDueAfterClose`).
    private func pendingDeleteWindowEnded(armedFor deadline: Date) async {
        guard pendingDeletes.deadline == deadline else { return }
        guard closingDeletes.isDisjoint(with: pendingDeletes.ids) else {
            deleteCommitDue = true
            return
        }
        guard let batch = pendingDeletes.expiredBatch(now: deadline) else { return }
        await commitPendingDeletes(batch)
    }

    /// A close finished: when the window already ran out and no row of the
    /// batch is closing any more, the batch commits now.
    private func commitIfDueAfterClose() async {
        guard deleteCommitDue, closingDeletes.isDisjoint(with: pendingDeletes.ids) else { return }
        deleteCommitDue = false
        await commitPendingDeletes(pendingDeletes.takeBatch())
    }

    /// Starts the DELETE of `ids` off the main actor, tracked by
    /// `deleteWrites`. A failure is logged here and rethrown.
    @discardableResult
    private func startSessionDeletes(_ ids: [Int64]) -> Task<Void, any Error> {
        let write = commitSessionDeletes
        let writes = deleteWrites
        writes.enter()
        return Task.detached {
            defer { writes.leave() }
            do {
                try await write(ids)
            } catch {
                NSLog("WorkbenchesViewModel: deleting %d session(s) failed: %@", ids.count, error.localizedDescription)
                throw error
            }
        }
    }

    /// The session lists (workbench id, nil = standalone) `entries` touch,
    /// in first-seen order.
    private static func sessionLists(of entries: [PendingSessionDeletes.Entry]) -> [Int64?] {
        var seen: Set<Int64?> = []
        return entries.map(\.workbenchID).filter { seen.insert($0).inserted }
    }
}
