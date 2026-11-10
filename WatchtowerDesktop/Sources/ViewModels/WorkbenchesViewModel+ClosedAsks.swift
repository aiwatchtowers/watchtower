import Foundation
import WatchtowerCore

/// "▸ N closed" (#1713 spec): the closed asks list in the ask drawer, beside
/// the session it belongs to, or over the workspace for the session-less lists.
extension WorkbenchesViewModel {
    /// Shows a closed list the way `showAsk` shows an ask: the workbench
    /// drilled into and, for a session's list, that session's pane on
    /// screen (terminal or Workchat, never started) — then the list in
    /// that pane's drawer. A session waiting in the Undo batch is gone as
    /// far as the owner can tell (PROJ-17).
    func showClosedList(projectID: Int64, sessionID: Int64?, automations: Bool = false) async {
        let ticket = beginSwitch(projectID: projectID)
        if selectedWorkbenchID != projectID { drill(into: projectID) }
        let key = OwnerAsksViewModel.ClosedListKey(projectID: projectID, sessionID: sessionID, automations: automations)
        if let sessionID {
            if pendingDeletes.ids.contains(sessionID) {
                reportSwitchError("That session no longer exists.", projectID: projectID, ticket: ticket)
                return
            }
            await revealTerminal(projectID: projectID, sessionID: sessionID, ticket: ticket)
            guard isLatestSwitch(ticket, projectID: projectID),
                  layout(projectID: projectID).showsSession(sessionID) else { return }
        } else {
            guard isLatestSwitch(ticket, projectID: projectID) else { return }
        }
        asks.drawerExpanded = false
        await asks.openClosedList(key)
    }

    /// A row of `key`'s list opened: its ask read-only in the same drawer,
    /// with the back row. A row whose ask is gone keeps the list, says so
    /// and reads it again.
    func openClosedAsk(_ askID: Int64, from key: OwnerAsksViewModel.ClosedListKey) async {
        asks.closedListCursors[key] = askID
        guard await showAsk(askID, projectID: key.projectID) else {
            await asks.closedAskGone(key)
            return
        }
        asks.noteOpenedFromClosedList(key, askID: askID)
    }

    /// Esc in the drawer with no field focused: back to the list the ask
    /// was opened from. False (nothing done) for an ask opened any other way.
    func escapeInAskDrawer(projectID: Int64) -> Bool {
        asks.backToClosedList(projectID: projectID)
    }
}
