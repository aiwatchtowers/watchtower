import Foundation
import WatchtowerCore

/// Every delete cleans up (board #1716, spec
/// 2026-11-10-auto-cleanup-on-session-delete §1, §3, §4; PROJ-17/18
/// amended). When the Undo window ends, a deleted workbench row is marked
/// (`delete_requested_at`, `commitPendingDeletes`) and queued here: per
/// workbench, one background cleanup at a time in request order, through
/// `SessionCleanupCenter.applyInBackground` — the `workbench cleanup
/// --apply` with no `--item` — sharing the workbench's slot with the Clean
/// Up screen and the placed sessions' cleanup (each waits for it, none is
/// refused). Different workbenches run in parallel.
///
/// The outcome (`SessionAutoCleanupOutcome.evaluate`) decides the row:
/// clean → the row is deleted (its cascades as before) and a quiet notice
/// shows; not fully cleaned → the row stays, marked, in the finished group
/// until the owner picks **Clean Up Again**, **Delete Anyway**, **Show in
/// Clean Up** or resumes it. A quit stops the queue (the rows keep their
/// mark and the next launch queues them again, once).
extension WorkbenchesViewModel {
    /// How long the clean notice shows (spec §3).
    nonisolated static let cleanupNoticeDuration: Duration = .seconds(6)

    /// Whether row `id` may be resumed: not while its background cleanup
    /// is queued or runs (spec §4), nor while a Delete Anyway or another
    /// Resume of it is in flight.
    func canResume(_ id: Int64) -> Bool {
        !closedForCleanup.contains(id) && !autoCleanupBusy.contains(id)
    }

    /// Whether a Not fully cleaned row's action may start now: it is marked,
    /// not queued, not in another transition, and no cleanup apply (the
    /// Clean Up screen's, a background one) runs on it.
    private func markedRowIsFree(_ id: Int64) -> Bool {
        notFullyCleaned[id] != nil && canResume(id) && !cleaningUpSessions.contains(id)
            && sessionCleanup?.isApplyingInBackground(sessionID: id) != true
            && sessionCleanup?.cleanupPhase(for: .session(id)) != .applying
    }

    /// The rows of workbench `projectID` whose background cleanup is queued
    /// or running (the panel header's "Cleaning up N sessions…").
    func autoCleanupCount(projectID: Int64) -> Int {
        autoCleanupQueue[projectID]?.count ?? 0
    }

    /// Queues `entries`' rows (marked already) for their background cleanup.
    func enqueueAutoCleanup(_ entries: [PendingSessionDeletes.Entry]) {
        for entry in entries {
            guard let workbenchID = entry.workbenchID else { continue }
            enqueueAutoCleanup(sessionID: entry.sessionID, workbenchID: workbenchID, title: entry.title)
        }
    }

    private func enqueueAutoCleanup(sessionID: Int64, workbenchID: Int64, title: String) {
        guard !closedForCleanup.contains(sessionID) else { return }
        autoCleanupTitles[sessionID] = title
        autoCleanupQueue[workbenchID, default: []].append(sessionID)
        startAutoCleanupWorker(workbenchID: workbenchID)
    }

    /// Launch (spec §4): every row still marked deleted whose terminal is
    /// not live — the app quit inside the Undo window or during a cleanup —
    /// is queued again, once per launch (a row that fails again shows Not
    /// fully cleaned; no retry loop). Runs after the session host's
    /// reattach, so a row whose run survived is seen live and left alone.
    func requeueDeletingRowsAtLaunch() async {
        guard !requeuedAtLaunch else { return }
        requeuedAtLaunch = true
        await hostReattach?.value
        let rows: [TerminalSession]
        do {
            rows = try await dbPool.read { try TerminalSessionQueries.fetchDeleting($0, projectID: nil) }
        } catch {
            NSLog("WorkbenchesViewModel: reading the sessions left to clean up failed: %@", error.localizedDescription)
            return
        }
        let live = terminalCenter?.liveIDs ?? []
        for row in rows {
            guard let workbenchID = row.projectID else { continue }
            if live.contains(row.id) {
                // Its terminal ends later: then it is cleaned up
                // (`deletedRowExited`).
                deletingLiveAtLaunch[row.id] = .init(sessionID: row.id, workbenchID: workbenchID, title: row.title)
            } else {
                enqueueAutoCleanup(sessionID: row.id, workbenchID: workbenchID, title: row.title)
            }
        }
    }

    /// A row still marked deleted whose terminal was live at launch ended:
    /// it is queued for its cleanup now. True when it was such a row.
    @discardableResult
    func deletedRowExited(_ id: Int64) -> Bool {
        guard let entry = deletingLiveAtLaunch.removeValue(forKey: id), let workbenchID = entry.workbenchID else {
            return false
        }
        enqueueAutoCleanup(sessionID: id, workbenchID: workbenchID, title: entry.title)
        return true
    }

    /// **Clean Up Again** on a Not fully cleaned row: the same background
    /// cleanup; on a clean outcome the row goes, else it is marked anew.
    /// The row stays in the finished group meanwhile, reading "Cleaning
    /// up…" with its actions off (spec §7).
    func cleanUpAgain(_ id: Int64) {
        guard markedRowIsFree(id), let row = notFullyCleanedRow(id), let workbenchID = row.projectID else { return }
        notFullyCleaned[id] = nil
        cleaningAgain.insert(id)
        enqueueAutoCleanup(sessionID: id, workbenchID: workbenchID, title: row.title)
    }

    /// Opening a Not fully cleaned row: its report, with the Cleanup
    /// section the apply stored (spec §3). It never starts the session.
    func openNotFullyCleaned(_ id: Int64, projectID: Int64) {
        guard notFullyCleanedRow(id) != nil else { return }
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        updated.show(.sessionReport(id))
        setLayout(updated, projectID: projectID)
    }

    /// A row out of the session lists that keeps its pane in the layout:
    /// queued or running its background cleanup, or Not fully cleaned.
    func keepsPaneWhileCleaning(_ id: Int64, projectID: Int64) -> Bool {
        closedForCleanup.contains(id) || cleaningAgain.contains(id)
            || notFullyCleanedSession(id, projectID: projectID) != nil
    }

    /// Workbench `projectID`'s Not fully cleaned row `id`, if listed: the
    /// report finds it there, since the session lists leave it out.
    func notFullyCleanedSession(_ id: Int64, projectID: Int64) -> TerminalSession? {
        notFullyCleanedRows[projectID]?.first { $0.id == id }
    }

    /// **Delete Anyway** on a Not fully cleaned row: the row is deleted now
    /// (its cascades as before); what the cleanup kept stays on disk, where
    /// a Clean Up screen sweep still lists it.
    func deleteAnyway(_ id: Int64) async {
        guard markedRowIsFree(id), let row = notFullyCleanedRow(id), let workbenchID = row.projectID else { return }
        // Resume and Clean Up Again refuse the row until the DELETE ended.
        autoCleanupBusy.insert(id)
        defer { autoCleanupBusy.remove(id) }
        do {
            try await startSessionDeletes([id]).value
        } catch {
            setSessionError("Could not delete the session: \(error.localizedDescription)", projectID: workbenchID)
            return
        }
        clearMark(id, workbenchID: workbenchID)
        await asks.load(projectID: workbenchID)
    }

    /// **Show in Clean Up** on a Not fully cleaned row: the Clean Up screen
    /// on that session's scope.
    @discardableResult
    func showInCleanUp(_ id: Int64) -> Task<Void, Never>? {
        guard let workbenchID = notFullyCleanedRow(id)?.projectID else { return nil }
        return openCleanupScreen(projectID: workbenchID, sessionID: id)
    }

    /// Resume of a Not fully cleaned row (spec §4): its `delete_requested_at`
    /// is cleared in a write of its own before the session starts, so it is
    /// an ordinary finished session again. The row is marked busy before
    /// the write — Clean Up Again and Delete Anyway refuse it until the mark
    /// is gone — and checked again after it. Throws `.cleaningUp` while the
    /// row is queued or in another transition, `.failed` when the write
    /// failed (reported on the page).
    func clearDeleteRequestForResume(_ session: TerminalSession) async throws {
        guard canResume(session.id) else { throw TargetStartError.cleaningUp }
        guard notFullyCleaned[session.id] != nil else { return }
        autoCleanupBusy.insert(session.id)
        defer { autoCleanupBusy.remove(session.id) }
        do {
            try await clearDeleteRequestWrite(session.id)
        } catch {
            let message = "Could not reopen the session: \(error.localizedDescription)"
            setSessionError(message, projectID: session.projectID)
            throw TargetStartError.failed(message)
        }
        if let workbenchID = session.projectID { clearMark(session.id, workbenchID: workbenchID) }
        guard !closedForCleanup.contains(session.id) else { throw TargetStartError.cleaningUp }
    }

    /// The quit (`QuitCoordinator`): no background cleanup starts any more,
    /// and a running one's process group gets SIGTERM, then SIGKILL after
    /// 5 s; the rows keep `delete_requested_at` for the next launch.
    func stopAutoCleanupForQuit() async {
        autoCleanupStopped = true
        await sessionCleanup?.stopBackgroundApplies()
    }

    /// Returns once no background cleanup queue has work (tests, and the
    /// callers that wait for an outcome).
    func autoCleanupIdle() async {
        while let worker = autoCleanupWorkers.values.first {
            await worker.value
        }
    }

    /// A workbench gone: its queued rows went with it; a run that has
    /// started ends on its own.
    func discardAutoCleanup(workbenchID: Int64) {
        let running = autoCleanupRunning[workbenchID]
        for id in autoCleanupQueue[workbenchID] ?? [] where id != running { autoCleanupTitles[id] = nil }
        autoCleanupQueue[workbenchID] = running.map { [$0] }
        notFullyCleanedRows[workbenchID] = nil
    }

    /// Reads workbench `projectID`'s Not fully cleaned rows: the deleting
    /// rows with a mark and no cleanup queued, and the ones Clean Up Again
    /// runs on. A failed read is logged and
    /// keeps the last list.
    func loadNotFullyCleaned(projectID: Int64) async {
        do {
            let rows = try await dbPool.read { try TerminalSessionQueries.fetchDeleting($0, projectID: projectID) }
            let queued = closedForCleanup
            notFullyCleanedRows[projectID] = rows.filter {
                cleaningAgain.contains($0.id) || (notFullyCleaned[$0.id] != nil && !queued.contains($0.id))
            }
        } catch {
            NSLog("WorkbenchesViewModel: reading workbench %lld's sessions not fully cleaned failed: %@",
                  projectID, error.localizedDescription)
        }
    }

    // MARK: The queue

    private func startAutoCleanupWorker(workbenchID: Int64) {
        guard autoCleanupWorkers[workbenchID] == nil, !autoCleanupStopped else { return }
        autoCleanupWorkers[workbenchID] = Task { [weak self] in
            await self?.runAutoCleanupQueue(workbenchID: workbenchID)
        }
    }

    private func runAutoCleanupQueue(workbenchID: Int64) async {
        while !autoCleanupStopped, let id = autoCleanupQueue[workbenchID]?.first {
            autoCleanupRunning[workbenchID] = id
            await cleanUpDeleted(id, workbenchID: workbenchID)
            autoCleanupRunning[workbenchID] = nil
            guard !autoCleanupStopped else { break }
            autoCleanupQueue[workbenchID]?.removeFirst()
            if autoCleanupQueue[workbenchID]?.isEmpty == true { autoCleanupQueue[workbenchID] = nil }
            await afterAutoCleanup(workbenchID: workbenchID)
        }
        autoCleanupWorkers[workbenchID] = nil
    }

    /// One row's background cleanup and its outcome (spec §3). Nothing is
    /// decided after the quit stopped the queue.
    private func cleanUpDeleted(_ id: Int64, workbenchID: Int64) async {
        let title = autoCleanupTitles[id] ?? ""
        let run = await sessionCleanup?.applyInBackground(sessionID: id, workbenchID: workbenchID)
            ?? .init(runError: CLIRunnerError.binaryNotFound.localizedDescription)
        guard !autoCleanupStopped else { return }
        autoCleanupTitles[id] = nil
        cleaningAgain.remove(id)
        switch SessionAutoCleanupOutcome.evaluate(result: run.result, title: title, runError: run.runError) {
        case let .clean(notice):
            do {
                try await startSessionDeletes([id]).value
            } catch {
                notFullyCleaned[id] = SessionAutoCleanupOutcome.deleteFailedMark(error.localizedDescription)
                return
            }
            notFullyCleaned[id] = nil
            notFullyCleanedRows[workbenchID]?.removeAll { $0.id == id }
            if notice != nil, let result = run.result { showCleanupNotice(title: title, result: result) }
        case let .notFullyCleaned(mark):
            notFullyCleaned[id] = mark
            // The report's Cleanup section reads what the apply stored.
            await loadCleanupRecord(sessionID: id)
        }
    }

    /// The lists after one outcome: the sessions, the asks (a delete
    /// unbound its session's asks, board #542) and the Not fully cleaned
    /// rows.
    private func afterAutoCleanup(workbenchID: Int64) async {
        await loadSessions(projectID: workbenchID)
        await asks.load(projectID: workbenchID)
        await loadNotFullyCleaned(projectID: workbenchID)
    }

    /// Shows the clean notice, joined with the ones still shown, for
    /// `cleanupNoticeDuration` from now.
    private func showCleanupNotice(title: String, result: SessionCleanupPlan) {
        cleanupNoticeEntries.append((title, result))
        cleanupNotice = SessionCleanupNotice.joined(cleanupNoticeEntries)
        cleanupNoticeTask?.cancel()
        let sleep = cleanupNoticeSleep
        cleanupNoticeTask = Task { [weak self] in
            await sleep(Self.cleanupNoticeDuration)
            guard !Task.isCancelled, let self else { return }
            cleanupNotice = nil
            cleanupNoticeEntries = []
        }
    }

    private func notFullyCleanedRow(_ id: Int64) -> TerminalSession? {
        notFullyCleanedRows.values.joined().first { $0.id == id }
    }

    private func clearMark(_ id: Int64, workbenchID: Int64) {
        notFullyCleaned[id] = nil
        notFullyCleanedRows[workbenchID]?.removeAll { $0.id == id }
    }
}
