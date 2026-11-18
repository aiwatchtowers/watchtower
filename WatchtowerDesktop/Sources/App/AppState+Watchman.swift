import Foundation
import WatchtowerCore

extension AppState {
    /// What the morning journal's Correct… and Open session reach (spec
    /// §10, D26): the shared `SessionLineDelivery` (PROJ-12) for a live
    /// session, the target's start path for a new one — in the owner's
    /// name, so never armed — and the Workbench page. `write` is the
    /// journal's own (its database init replaces it).
    func watchmanJournalActions() -> WatchmanJournalViewModel.Actions {
        WatchmanJournalViewModel.Actions(
            write: { _ in false },
            isLive: { [weak self] in self?.sessionLineDelivery?.isLive($0) ?? false },
            deliver: { [weak self] line, itemID, sessionID, onHeld in
                guard let delivery = self?.sessionLineDelivery else { return .noSession }
                return await delivery.deliverLine(line, key: .watchmanCorrection(itemID), sessionID: sessionID,
                                                  onHeldEvent: onHeld)
            },
            startSession: { [weak self] item, line in
                guard let workbenches = self?.workbenchesViewModel else {
                    throw WatchmanCorrectionError(reason: WatchmanJournalViewModel.workbenchesNotLoaded)
                }
                return try await Self.startCorrectionSession(workbenches, item: item, line: line)
            },
            open: { [weak self] in self?.navigateToWorkbench($0) }
        )
    }

    /// A new session with the correction as its first instruction: on the
    /// item's target (Work on it's start path, always a new session), else
    /// in its workbench. It starts in the background; Open session shows it.
    private static func startCorrectionSession(
        _ workbenches: WorkbenchesViewModel, item: WatchmanItem, line: String
    ) async throws -> Int64 {
        if item.targetID > 0 {
            do {
                return try await workbenches.startForTarget(
                    targetID: item.targetID, prompt: line, mode: .new, placement: .background).id
            } catch let error as WorkbenchesViewModel.TargetStartError {
                throw WatchmanCorrectionError(
                    reason: WatchmanJournalViewModel.startFailure(error, targetID: item.targetID))
            }
        }
        guard let project = await workbenches.project(id: item.workbenchID) else {
            throw WatchmanCorrectionError(reason: WatchmanJournalViewModel.workbenchGone)
        }
        guard let row = await workbenches.startNewSession(
            project: project, title: TerminalSessionNaming.provisional(now: Date()), prompt: line,
            placement: .background, agent: workbenches.currentDefaultAgent()) else {
            throw WatchmanCorrectionError(reason: WatchmanJournalViewModel.sessionDidNotStart)
        }
        return row.id
    }
}
