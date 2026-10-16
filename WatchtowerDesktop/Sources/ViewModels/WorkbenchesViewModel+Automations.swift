import Foundation
import WatchtowerCore

/// The workbench's automation recipes indexed from the app (spec §13.4,
/// ruling R-P5-9), and the run steps' links into the page.
extension WorkbenchesViewModel {
    /// A workbench page came on screen: `automations rescan --workbench N`
    /// for every page — the daemon never reads a protected folder, and an
    /// unprotected one rescans harmlessly (no Swift copy of Go's list). It
    /// belongs to this view model, so leaving the page does not cancel it.
    func workbenchPageOpened(projectID: Int64) {
        startAutomationRescan(workbenchID: projectID)
    }

    /// The page's folder watcher saw a change under `.watchtower/automations/`
    /// (`CodeFilesCenter.onAutomationRecipesChanged`): one rescan once the
    /// changes settle for `automationRescanDelay`.
    func automationRecipesChanged(workbenchID: Int64) {
        automationRescanTimers[workbenchID]?.cancel()
        let delay = automationRescanDelay
        automationRescanTimers[workbenchID] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            // Out of the map first: a later change must not cancel the
            // rescan itself (the runner would kill its process).
            automationRescanTimers[workbenchID] = nil
            startAutomationRescan(workbenchID: workbenchID)
        }
    }

    /// The feature came on (or its state loaded, on): the rescans asked
    /// for meanwhile run now, once each.
    func automationsFeatureTurnedOn() {
        let deferred = automationRescansDeferred
        automationRescansDeferred = []
        for workbenchID in deferred.sorted() {
            startAutomationRescan(workbenchID: workbenchID)
        }
    }

    /// Best effort, logged: a failed rescan leaves the index as it was.
    /// Only while the feature is on — asked for before, it waits for
    /// `automationsFeatureTurnedOn`; one at a time per workbench — an ask
    /// while one runs becomes one more rescan after it, which sees a change
    /// the running one may have missed.
    private func startAutomationRescan(workbenchID: Int64) {
        guard let rescanAutomations else { return }
        guard isAutomationsFeatureOn() else {
            automationRescansDeferred.insert(workbenchID)
            return
        }
        guard !automationRescansInFlight.contains(workbenchID) else {
            automationRescansAgain.insert(workbenchID)
            return
        }
        automationRescansInFlight.insert(workbenchID)
        Task { [weak self] in
            do {
                try await rescanAutomations(workbenchID)
            } catch {
                NSLog("WorkbenchesViewModel: automations rescan of workbench %lld failed: %@",
                      workbenchID, error.localizedDescription)
            }
            guard let self else { return }
            automationRescansInFlight.remove(workbenchID)
            if automationRescansAgain.remove(workbenchID) != nil {
                startAutomationRescan(workbenchID: workbenchID)
            }
        }
    }

    /// A run step's session link (the Automations card): its workbench
    /// drilled into and the session put on screen — shown, never started
    /// (a stopped one offers Resume). A session deleted since says so.
    func showAutomationSession(_ sessionID: Int64, projectID: Int64) async {
        let ticket = beginSwitch(projectID: projectID)
        drill(into: projectID)
        guard await loadSessions(projectID: projectID), isLatestSwitch(ticket, projectID: projectID) else { return }
        guard terminalSessions[projectID]?.contains(where: { $0.id == sessionID }) == true,
              !pendingDeletes.ids.contains(sessionID) else {
            reportSwitchError("That session no longer exists.", projectID: projectID, ticket: ticket)
            return
        }
        await revealTerminal(projectID: projectID, sessionID: sessionID, ticket: ticket)
    }
}
