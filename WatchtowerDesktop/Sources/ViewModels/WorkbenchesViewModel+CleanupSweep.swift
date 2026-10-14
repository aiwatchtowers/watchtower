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

    /// The sweep sheet opened: plans the whole workbench with every live
    /// terminal passed. Opening it answers the hint: it goes away and is
    /// never planned for again. Cancelling the caller leaves the plan
    /// running.
    func planSweepForSheet(projectID: Int64) async {
        guard let center = sessionCleanup else { return }
        cleanupHints[projectID] = nil
        cleanupHintShown(projectID: projectID)
        await center.startSweepPlan(workbenchID: projectID).value
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
    /// apply still running is kept (it forgets when it ends).
    func closeSweepSheet(projectID: Int64) {
        openSweepSheets.remove(projectID)
        guard sweepRuns[projectID] == nil else { return }
        sessionCleanup?.forgetCleanup(.workbench(projectID))
    }

    // MARK: One-time hint

    /// The page of workbench `projectID` came on screen: unless its hint
    /// was shown before, plans the sweep once this launch and, when the
    /// removable worktrees hold over 1 GB, puts up the hint. Nothing runs
    /// while the sweep sheet is open or the sweep is busy. The plan belongs
    /// to the center and the hint to this view model, so leaving the page
    /// meanwhile loses neither.
    func checkCleanupHint(projectID: Int64) async {
        guard let center = sessionCleanup, !defaults.bool(forKey: Self.cleanupHintShownKey(projectID)),
              !cleanupHintChecked.contains(projectID), !openSweepSheets.contains(projectID),
              sweepRuns[projectID] == nil, center.cleanupPhase(for: .workbench(projectID)) == .idle
        else { return }
        cleanupHintChecked.insert(projectID)
        await center.startSweepPlan(workbenchID: projectID).value
        // The sheet opened meanwhile: the plan on screen is the sheet's.
        guard !openSweepSheets.contains(projectID) else { return }
        if case let .ready(plan) = center.cleanupPhase(for: .workbench(projectID)) {
            cleanupHints[projectID] = SessionCleanupPresentation.sweepHint(plan)
        }
        center.forgetCleanup(.workbench(projectID))
    }

    /// The hint came on screen: it is never planned for again.
    func cleanupHintShown(projectID: Int64) {
        defaults.set(true, forKey: Self.cleanupHintShownKey(projectID))
    }

    /// The hint's ✕.
    func dismissCleanupHint(projectID: Int64) {
        cleanupHints[projectID] = nil
    }
}
