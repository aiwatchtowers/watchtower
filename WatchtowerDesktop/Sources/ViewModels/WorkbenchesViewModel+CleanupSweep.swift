import Foundation
import WatchtowerCore

/// **Clean Up Old Worktrees…** — the workbench-wide sweep (board #535, spec
/// 2026-10-12-session-cleanup §9/§12) — and its one-time hint (open
/// question 2, owner approved, ask #193), driven through
/// `SessionCleanupCenter` with the workbench scope.
///
/// The sweep lists every worktree and branch of the workbench repository
/// with an owner hint; nothing is ticked, and an apply names exactly the
/// ticked keys of a known kind. Plans run in tasks the center owns and
/// applies in tasks this view model owns (`sweepRuns`), so closing the sheet
/// or leaving the page cancels neither.
extension WorkbenchesViewModel {
    /// The UserDefaults key remembering that workbench `workbenchID`'s
    /// cleanup hint was shown.
    nonisolated static func cleanupHintShownKey(_ workbenchID: Int64) -> String {
        "projects.cleanupHintShown.\(workbenchID)"
    }

    // MARK: Sweep sheet

    /// A ready sweep plan younger than this is shown as it is when the
    /// sheet opens; an older one is planned again.
    nonisolated static let sweepPlanReuseWindow: TimeInterval = 10 * 60

    /// The sweep sheet opened: plans the whole workbench with every live
    /// terminal passed — unless a plan younger than `sweepPlanReuseWindow`
    /// is ready (the hint's) or a sheet's plan still runs (one closed
    /// mid-plan): walking every worktree again takes minutes on a big
    /// repository (board #704). A sheet's plan is stopped and fails after
    /// `cleanupHintTimeLimit`. Opening it answers the hint: it goes away and
    /// is never planned for again. Cancelling the caller leaves the plan
    /// running.
    func planSweepForSheet(projectID: Int64) async {
        guard let center = sessionCleanup else { return }
        cleanupHints[projectID] = nil
        cleanupHintShown(projectID: projectID)
        let scope = SessionCleanupScope.workbench(projectID)
        switch center.cleanupPhase(for: scope) {
        case .ready where (center.readyPlanAge(for: scope) ?? .infinity) < Self.sweepPlanReuseWindow:
            return
        case .planning where cleanupHintRunning != projectID:
            // A hint plan is not waited for: its watchdog or the page
            // leaving may stop it.
            if let run = center.runningPlan(for: scope) {
                await run.value
                return
            }
        default:
            break
        }
        await center.startSweepPlan(workbenchID: projectID, timeLimit: cleanupHintTimeLimit).value
    }

    /// The sweep's phase for workbench `projectID`; idle without a center.
    func sweepPhase(projectID: Int64) -> SessionCleanupPhase {
        sessionCleanup?.cleanupPhase(for: .workbench(projectID)) ?? .idle
    }

    /// The ticked items the sweep would remove: pending removals of a known
    /// kind in the ready plan among `ticked` (an unknown kind is listed, never
    /// applied); empty in any other phase.
    func sweepCleanupChoice(projectID: Int64, ticked: Set<String>) -> [SessionCleanupItem] {
        guard case let .ready(plan) = sweepPhase(projectID: projectID) else { return [] }
        return plan.removableItems(among: ticked)
    }

    /// The sheet's **Clean Up**: applies exactly the ticked pending removals
    /// in a run this view model owns. A failure the sheet did not show (it
    /// was closed when the apply ended) goes on the page; once the sheet is
    /// gone the phase is forgotten. True when nothing failed; false, with
    /// nothing run, when nothing is ticked or a sweep apply already runs.
    @discardableResult
    func applySweepCleanup(projectID: Int64, ticked: Set<String>) async -> Bool {
        let keys = sweepCleanupChoice(projectID: projectID, ticked: ticked).map(\.key)
        guard let center = sessionCleanup, !keys.isEmpty, sweepRuns[projectID] == nil else { return false }
        let run = Task {
            let ok = await center.applySweep(workbenchID: projectID, items: keys)
            self.finishSweepCleanup(projectID: projectID, center: center, ok: ok)
            return ok
        }
        sweepRuns[projectID] = run
        return await run.value
    }

    private func finishSweepCleanup(projectID: Int64, center: SessionCleanupCenter, ok: Bool) {
        sweepRuns[projectID] = nil
        guard !openSweepSheets.contains(projectID) else { return }
        if !ok {
            let reason = center.failureText(for: .workbench(projectID)) ?? "unknown error"
            setSessionError("Cleanup of old worktrees failed: \(reason)", projectID: projectID)
        }
        center.forgetCleanup(.workbench(projectID))
    }

    /// The sweep sheet came on screen.
    func sweepSheetAppeared(projectID: Int64) {
        openSweepSheets.insert(projectID)
    }

    /// The sweep sheet left the screen (closed, or torn down with the page).
    /// An apply still running reports and forgets when it ends.
    func sweepSheetDisappeared(projectID: Int64) {
        openSweepSheets.remove(projectID)
    }

    /// The sheet's Cancel, Done or Close: forgets its plan or result. An
    /// apply still running is kept (it forgets when it ends), and so is a
    /// plan still running — the next open shows it instead of starting
    /// over; its time limit still stops it.
    func closeSweepSheet(projectID: Int64) {
        openSweepSheets.remove(projectID)
        guard sweepRuns[projectID] == nil, let center = sessionCleanup,
              center.cleanupPhase(for: .workbench(projectID)) != .planning else { return }
        center.forgetCleanup(.workbench(projectID))
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
    /// the hint was shown before, the sweep sheet opened, the workbench was
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
        let run = center.startSweepPlan(workbenchID: projectID)
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
              !cleanupHintChecked.contains(projectID), !openSweepSheets.contains(projectID),
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
        // The sheet opened meanwhile: the plan on screen is the sheet's.
        guard !openSweepSheets.contains(projectID) else { return }
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
                // Kept for the sheet the hint opens (board #704).
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

    /// The hint's ✕: its plan is forgotten unless a sheet shows it.
    func dismissCleanupHint(projectID: Int64) {
        cleanupHints[projectID] = nil
        guard !openSweepSheets.contains(projectID), sweepRuns[projectID] == nil,
              let center = sessionCleanup, case .ready = center.cleanupPhase(for: .workbench(projectID))
        else { return }
        center.forgetCleanup(.workbench(projectID))
    }
}
