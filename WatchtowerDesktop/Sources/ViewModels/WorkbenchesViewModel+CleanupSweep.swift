import Foundation
import WatchtowerCore

/// The Clean Up screen's state per workbench (board #1107, spec
/// 2026-10-26-worktree-cleanup-screen §3.1): in memory only — nothing about
/// it is saved, and a relaunch never brings it back.
struct CleanupScreenState: Equatable {
    /// The whole workbench (the CLI's `--sweep`) or one session.
    var scope: SessionCleanupScope
    /// The ticked rows' ids; nothing is ticked by itself in either scope.
    var ticks: Set<String> = []
    var filters = CleanupFilters()
    var sort: CleanupSort = .size
    var ascending = false
    /// The row clicked last, the anchor of a ⇧-click range.
    var lastClicked: String?
    var resultDismissed = false
    /// The keys the screen's last apply sent: only those count as kept in
    /// the result bar (`CleanupScreenModel.resultText`). Empty after a plan.
    var sentKeys: Set<String> = []
}

/// The Clean Up screen (board #1107, spec 2026-10-26-worktree-cleanup-screen
/// §3/§5) — the one place to pick what goes, for the whole workbench or one
/// session — and the one-time hint (open question 2 of the 2026-10-12
/// cleanup spec, owner approved, ask #193), driven through
/// `SessionCleanupCenter`'s streamed runs.
///
/// Nothing is ticked by itself, and an apply names exactly the ticked rows'
/// keys of a known kind (a worktree row: the worktree, its removable branch
/// and its bundles' entries, PROJ-18 2026-10-26 amendment). Plans run in
/// tasks the center owns and applies in tasks this view model owns
/// (`sweepRuns`), so closing the screen or leaving the page cancels neither.
extension WorkbenchesViewModel {
    /// The UserDefaults key remembering that workbench `workbenchID`'s
    /// cleanup hint was shown.
    nonisolated static func cleanupHintShownKey(_ workbenchID: Int64) -> String {
        "projects.cleanupHintShown.\(workbenchID)"
    }

    // MARK: Clean Up screen

    /// A ready plan younger than this is shown as it is when the screen
    /// opens; an older one is planned again.
    nonisolated static let sweepPlanReuseWindow: TimeInterval = 10 * 60

    /// Whether workbench `projectID`'s page shows the Clean Up screen.
    func cleanupScreenOpen(projectID: Int64) -> Bool {
        cleanupScreens[projectID] != nil
    }

    /// Whether a Clean Up screen shows session `sessionID`'s scope.
    func cleanupScreenShows(sessionID: Int64) -> Bool {
        cleanupScreens.values.contains { $0.scope == .session(sessionID) }
    }

    /// Opens the Clean Up screen on workbench `projectID` — the whole
    /// workbench, or session `sessionID` alone — and plans its scope, with
    /// every live terminal passed: unless a plan younger than
    /// `sweepPlanReuseWindow` is ready (the hint's) or one still runs (the
    /// screen closed mid-plan) — walking every worktree again takes minutes
    /// on a big repository (board #704) — or the scope applies. A plan is
    /// stopped and fails after `cleanupHintTimeLimit`. Opening the
    /// workbench scope answers the hint: it goes away and is never planned
    /// for again. Opening the scope already on screen keeps its ticks.
    /// Returns a task that waits for the plan the screen shows (finished
    /// when none runs); cancelling it stops nothing.
    @discardableResult
    func openCleanupScreen(projectID: Int64, sessionID: Int64? = nil) -> Task<Void, Never> {
        let scope = sessionID.map(SessionCleanupScope.session) ?? .workbench(projectID)
        if let shown = cleanupScreens[projectID]?.scope, shown != scope {
            // Leaving the old scope is closing it: its result goes.
            closeCleanupScreen(projectID: projectID)
        }
        if cleanupScreens[projectID] == nil {
            cleanupScreens[projectID] = CleanupScreenState(scope: scope)
        }
        return planShownScope(projectID: projectID, scope: scope)
    }

    /// The screen's ✕, or a segment of the title row: the workspace shows
    /// again. Its ready plan or result is forgotten; a plan still running
    /// is kept (the next open shows it instead of starting over; its time
    /// limit still stops it) and so is an apply (it forgets when it ends).
    func closeCleanupScreen(projectID: Int64) {
        guard let scope = cleanupScreens.removeValue(forKey: projectID)?.scope else { return }
        guard sweepRuns[projectID] == nil, let center = sessionCleanup,
              center.cleanupPhase(for: scope) != .planning else { return }
        center.forgetCleanup(scope)
    }

    /// The session chip's ✕: the screen shows the whole workbench, planned
    /// afresh (its own CLI mode), and the session's plan is stopped. Nothing
    /// while a cleanup apply of the workbench runs. Returns the plan shown.
    @discardableResult
    func widenCleanupScope(projectID: Int64) -> Task<Void, Never> {
        guard let state = cleanupScreens[projectID], case .session = state.scope,
              canRefreshCleanup(projectID: projectID) else { return Task {} }
        sessionCleanup?.forgetCleanup(state.scope)
        let scope = SessionCleanupScope.workbench(projectID)
        cleanupScreens[projectID] = CleanupScreenState(scope: scope, filters: state.filters)
        return planShownScope(projectID: projectID, scope: scope)
    }

    /// **Refresh**: plans the screen's scope again; the rows already shown
    /// stay until the new run lists its own, and ticks on rows that are no
    /// longer removable drop. Nothing while a cleanup apply of the
    /// workbench runs. Returns the new plan.
    @discardableResult
    func refreshCleanup(projectID: Int64) -> Task<Void, Never> {
        guard let scope = cleanupScreens[projectID]?.scope, canRefreshCleanup(projectID: projectID),
              let center = sessionCleanup else { return Task {} }
        cleanupScreens[projectID]?.sentKeys = []
        cleanupScreens[projectID]?.resultDismissed = false
        return startScreenPlan(scope, projectID: projectID, center: center)
    }

    /// The result bar's **Retry**: after a failed apply, a new apply of the
    /// rows still ticked (it re-plans first, as every apply does); after a
    /// failed plan, a new plan (the rows already listed stay until it
    /// lists its own, ask #631).
    func retryCleanup(projectID: Int64) {
        guard let state = cleanupScreens[projectID], let center = sessionCleanup,
              case .failed = center.cleanupPhase(for: state.scope) else { return }
        // Every plan empties `sentKeys` and every apply fills it, so an
        // empty set means the failed run was a plan.
        if state.sentKeys.isEmpty {
            refreshCleanup(projectID: projectID)
        } else {
            Task { await self.applyCleanupScreen(projectID: projectID) }
        }
    }

    /// False while any cleanup apply of the workbench runs — the screen's,
    /// of either scope, or Delete and Clean Up's: Refresh and Clean Up…
    /// are disabled then ("Another cleanup is running").
    func canRefreshCleanup(projectID: Int64) -> Bool {
        sessionCleanup != nil && !cleanupApplyRuns(projectID: projectID)
    }

    /// True while a cleanup apply of workbench `projectID` runs: the Delete
    /// dialog's **Delete and Clean Up** waits (Delete Only does not).
    func deleteAndCleanUpBlocked(projectID: Int64) -> Bool {
        cleanupApplyRuns(projectID: projectID)
    }

    /// Whether a cleanup apply of workbench `projectID` runs: the center's,
    /// the screen's, or a Delete and Clean Up still closing its terminal or
    /// re-planning before its apply starts.
    private func cleanupApplyRuns(projectID: Int64) -> Bool {
        sessionCleanup?.isApplying(workbenchID: projectID) == true || sweepRuns[projectID] != nil
            || cleanupRunWorkbenches.values.contains(projectID)
    }

    /// The screen's streamed run so far: its rows, checks and stage.
    func cleanupScreenProgress(projectID: Int64) -> SessionCleanupProgress? {
        cleanupScreens[projectID].flatMap { sessionCleanup?.progress(for: $0.scope) }
    }

    /// The screen's rows and texts over its run so far; nil before any.
    func cleanupScreenModel(projectID: Int64, now: Date = Date()) -> CleanupScreenModel? {
        cleanupScreenProgress(projectID: projectID).map {
            CleanupScreenModel(items: $0.items, checking: $0.checking, sizing: $0.sizing, removing: $0.removing, now: now)
        }
    }

    /// The confirmation's **Remove**: applies exactly the ticked rows' keys
    /// (`CleanupScreenModel.applyKeys`: rows that can be chosen, known
    /// kinds only, ticks on rows no longer removable dropped) in a run
    /// this view model owns. In a session's scope the row is busy
    /// meanwhile — no delete, no start fresh — but a live session's
    /// terminal stays reachable, and the report's Cleanup line reloads
    /// after. A failure the screen did not show (it was closed, or shows
    /// another scope, when the apply ended) goes on the page; then the
    /// phase is forgotten. True when nothing failed; false, with nothing
    /// launched, when nothing is ticked or a cleanup apply of the
    /// workbench already runs.
    @discardableResult
    func applyCleanupScreen(projectID: Int64) async -> Bool {
        guard let state = cleanupScreens[projectID], let center = sessionCleanup,
              canRefreshCleanup(projectID: projectID),
              let model = cleanupScreenModel(projectID: projectID) else { return false }
        let keys = model.applyKeys(for: model.liveTicks(state.ticks))
        guard !keys.isEmpty else { return false }
        var title = ""
        if case let .session(sessionID) = state.scope {
            guard !cleaningUpSessions.contains(sessionID) else { return false }
            cleaningUpSessions.insert(sessionID)
            title = sessions.first { $0.id == sessionID }?.title ?? "the session"
        }
        cleanupScreens[projectID]?.sentKeys = Set(keys)
        cleanupScreens[projectID]?.resultDismissed = false
        let apply = center.startStreamedApply(state.scope, workbenchID: projectID, items: keys)
        let run = Task {
            let ok = await apply.value
            await self.finishScreenApply(projectID: projectID, scope: state.scope, title: title, center: center, ok: ok)
            return ok
        }
        sweepRuns[projectID] = run
        return await run.value
    }

    private func finishScreenApply(
        projectID: Int64, scope: SessionCleanupScope, title: String, center: SessionCleanupCenter, ok: Bool
    ) async {
        // Read before the await: a close meanwhile would forget the phase.
        let failure = ok ? nil : center.failureText(for: scope) ?? "unknown error"
        if case let .session(sessionID) = scope {
            await loadCleanupRecord(sessionID: sessionID)
            cleaningUpSessions.remove(sessionID)
        }
        sweepRuns[projectID] = nil
        // The screen on this scope shows the result, a failure included.
        guard cleanupScreens[projectID]?.scope != scope else { return }
        if let failure {
            switch scope {
            case .workbench: setSessionError("Cleanup of old worktrees failed: \(failure)", projectID: projectID)
            case .session: setSessionError("Cleanup of “\(title)” failed: \(failure)", projectID: projectID)
            }
        }
        center.forgetCleanup(scope)
    }

    /// A plan the center owns; the returned task only waits for it, so
    /// cancelling it stops nothing.
    private func startScreenPlan(_ scope: SessionCleanupScope, projectID: Int64, center: SessionCleanupCenter) -> Task<Void, Never> {
        let run = center.startStreamedPlan(scope, workbenchID: projectID, timeLimit: cleanupHintTimeLimit)
        return Task { await run.value }
    }

    /// Plans `scope` for the screen unless its plan can be shown as it is
    /// (see `openCleanupScreen`).
    private func planShownScope(projectID: Int64, scope: SessionCleanupScope) -> Task<Void, Never> {
        guard let center = sessionCleanup else { return Task {} }
        if case .workbench = scope {
            cleanupHints[projectID] = nil
            cleanupHintShown(projectID: projectID)
        }
        let hintPlans = scope == .workbench(projectID) && cleanupHintRunning == projectID
        switch center.cleanupPhase(for: scope) {
        case .ready where (center.readyPlanAge(for: scope) ?? .infinity) < Self.sweepPlanReuseWindow:
            return Task {}
        case .planning where !hintPlans:
            // A hint plan is not waited for: its watchdog or the page
            // leaving may stop it.
            if let run = center.runningPlan(for: scope) { return Task { await run.value } }
        case .applying, .done, .failed:
            // Only a screen on this scope keeps a result: it shows it.
            return Task {}
        default:
            break
        }
        return startScreenPlan(scope, projectID: projectID, center: center)
    }

    // MARK: One-time hint

    /// The UserDefaults key holding when workbench `workbenchID`'s hint plan
    /// last found 1 GB or less (seconds since 1970).
    nonisolated static func cleanupHintCheckedAtKey(_ workbenchID: Int64) -> String {
        "projects.cleanupHintCheckedAt.\(workbenchID)"
    }

    /// A workbench whose hint plan found 1 GB or less is not planned for
    /// again for this long.
    nonisolated static let cleanupHintRecheckInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Runs in the page's `.task(id: project.id)`, so it is cancelled when
    /// the page goes away or shows another workbench. Once the page has
    /// stayed on screen `cleanupHintDelay` (30 s), plans the sweep — unless
    /// the hint was shown before, the Clean Up screen is open, the workbench was
    /// checked within 7 days or this launch, or another workbench's hint
    /// plan runs (one at a time, app-wide). Leaving the page stops a running
    /// plan. Over 1 GB of removable worktrees puts up the hint and writes
    /// the shown key at once: the result can only land while the page is on
    /// screen. At or below the line, the check time is stored.
    func watchCleanupHint(projectID: Int64) async {
        guard cleanupHintDue(projectID) else { return }
        do { try await cleanupHintSleep(cleanupHintDelay) } catch { return }
        guard !Task.isCancelled, cleanupHintDue(projectID), cleanupHintRunning == nil,
              let center = sessionCleanup else { return }
        cleanupHintRunning = projectID
        defer { cleanupHintRunning = nil }
        let run = center.startStreamedPlan(.workbench(projectID), workbenchID: projectID)
        // A stalled plan (a read blocked on a dead mount) never holds the
        // one slot for longer than the limit.
        let watchdog = Task { [limit = cleanupHintTimeLimit] in
            try? await Task.sleep(for: limit)
            if !Task.isCancelled { run.cancel() }
        }
        defer { watchdog.cancel() }
        await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
        finishCleanupHint(projectID: projectID, center: center, pageLeft: Task.isCancelled)
    }

    private func cleanupHintDue(_ projectID: Int64) -> Bool {
        guard let center = sessionCleanup, !defaults.bool(forKey: Self.cleanupHintShownKey(projectID)),
              !cleanupHintChecked.contains(projectID), !cleanupScreenOpen(projectID: projectID),
              sweepRuns[projectID] == nil, center.cleanupPhase(for: .workbench(projectID)) == .idle
        else { return false }
        guard let checkedAt = defaults.object(forKey: Self.cleanupHintCheckedAtKey(projectID)) as? Double else {
            return true
        }
        // A stamp in the future (the clock was set back since) is due.
        let age = cleanupHintNow().timeIntervalSince1970 - checkedAt
        return age < 0 || age >= Self.cleanupHintRecheckInterval
    }

    /// Ends a hint plan. `pageLeft`: its page went away — the plan was
    /// stopped, or it had landed just before; either way nothing is shown
    /// or stored and a later visit tries again.
    func finishCleanupHint(projectID: Int64, center: SessionCleanupCenter, pageLeft: Bool) {
        let scope = SessionCleanupScope.workbench(projectID)
        // The screen opened meanwhile: no hint behind it. On the workbench
        // scope the plan is the screen's; on a session's the hint's plan is
        // dropped unchecked, so a later visit tries again.
        if let shown = cleanupScreens[projectID]?.scope {
            if shown != scope { center.forgetCleanup(scope) }
            return
        }
        guard !pageLeft else {
            center.forgetCleanup(scope)
            return
        }
        cleanupHintChecked.insert(projectID)
        switch center.cleanupPhase(for: scope) {
        case let .ready(plan):
            if let hint = SessionCleanupPresentation.sweepHint(plan) {
                cleanupHints[projectID] = hint
                cleanupHintShown(projectID: projectID)
                // Kept for the screen the hint opens (board #704).
                return
            } else if SessionCleanupPresentation.sweepSizesKnown(plan) {
                // An unmeasured worktree leaves it open: not snoozed.
                defaults.set(cleanupHintNow().timeIntervalSince1970, forKey: Self.cleanupHintCheckedAtKey(projectID))
            }
        case let .failed(message):
            NSLog("WorkbenchesViewModel: the cleanup hint's sweep plan of workbench %lld failed: %@",
                  projectID, message)
        case .idle:
            NSLog("WorkbenchesViewModel: the cleanup hint's sweep plan of workbench %lld was stopped after %@",
                  projectID, String(describing: cleanupHintTimeLimit))
        default:
            break
        }
        center.forgetCleanup(scope)
    }

    /// The hint is up, or the owner opened the sweep: it is never planned
    /// for again.
    func cleanupHintShown(projectID: Int64) {
        defaults.set(true, forKey: Self.cleanupHintShownKey(projectID))
    }

    /// The hint's ✕: its plan is forgotten unless the screen shows it.
    func dismissCleanupHint(projectID: Int64) {
        cleanupHints[projectID] = nil
        guard !cleanupScreenOpen(projectID: projectID), sweepRuns[projectID] == nil,
              let center = sessionCleanup, case .ready = center.cleanupPhase(for: .workbench(projectID))
        else { return }
        center.forgetCleanup(.workbench(projectID))
    }
}
