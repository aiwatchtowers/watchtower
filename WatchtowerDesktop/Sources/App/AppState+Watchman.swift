import Foundation
import GRDB
import WatchtowerCore

extension AppState {
    /// The arm sheet's session titles and its instruction pre-fill, read
    /// from `watchman_instructions` before each sheet (tuning spec D7).
    func wireWatchmanSheets(dbPool: DatabasePool) {
        watchmanCenter?.sessionTitle = { [weak self] in self?.workbenchesViewModel?.sessionTitle($0) }
        watchmanCenter?.readInstruction = { scope in
            try await dbPool.read { try WatchmanInstructionQueries.text($0, scope: scope) }
        }
    }

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
    /// in its workbench. Both start in the background with a checked launch:
    /// a launch that did not run throws (Not sent, Retry). Open session shows it.
    private static func startCorrectionSession(
        _ workbenches: WorkbenchesViewModel, item: WatchmanItem, line: String
    ) async throws -> Int64 {
        do {
            if item.targetID > 0 {
                return try await workbenches.startForTarget(
                    targetID: item.targetID, prompt: line, mode: .new, placement: .background).id
            }
            return try await workbenches.startInBackground(
                projectID: item.workbenchID, title: TerminalSessionNaming.provisional(now: Date()), prompt: line).id
        } catch let error as WorkbenchesViewModel.TargetStartError {
            throw WatchmanCorrectionError(reason: WatchmanJournalViewModel.startFailure(error, targetID: item.targetID))
        }
    }
}
