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
    /// and reads it again; a read that fails says that instead — an error
    /// is never "gone".
    func openClosedAsk(_ askID: Int64, from key: OwnerAsksViewModel.ClosedListKey) async {
        asks.closedListCursors[key] = askID
        // A switch like any other (board #187): of two quick clicks the
        // later one wins, whichever read finishes first.
        let ticket = beginSwitch(projectID: key.projectID)
        let found: OwnerAsk?
        do {
            found = try await asks.linkedAsk(askID: askID, projectID: key.projectID)
        } catch {
            guard isLatestSwitch(ticket, projectID: key.projectID) else { return }
            asks.closedListNotices[key] = ClosedAskListCopy.openFailed(error.localizedDescription)
            return
        }
        guard isLatestSwitch(ticket, projectID: key.projectID) else { return }
        guard found != nil else {
            await asks.closedAskGone(key)
            return
        }
        guard await showAsk(askID, projectID: key.projectID) else { return }
        asks.noteOpenedFromClosedList(key, askID: askID)
    }

    /// A key in a closed list with nothing focused (the drawer's key
    /// catcher): ↑/↓ move the cursor among `visibleIDs`, Return opens the
    /// cursor's row only while it is on screen (a row the search hid is
    /// never opened blind), Esc clears the search, else closes the drawer.
    /// False when it did nothing; `.search` is the view's (its field).
    @discardableResult
    func pressInClosedList(
        _ action: ClosedAskListModel.KeyAction,
        key: OwnerAsksViewModel.ClosedListKey,
        visibleIDs ids: [Int64]
    ) -> Bool {
        // Only after a click in the drawer, as its ask keys (board #412).
        guard asks.drawerKeysActive.contains(key.projectID) else { return false }
        switch action {
        case .up, .down:
            asks.moveClosedListCursor(key, ids: ids, forward: action == .down)
            return true
        case .open:
            guard let id = asks.closedListCursors[key], ids.contains(id) else { return false }
            Task { await openClosedAsk(id, from: key) }
            return true
        case .escape:
            if (asks.closedListQueries[key] ?? "").isEmpty {
                asks.closeDrawer(projectID: key.projectID)
            } else {
                asks.closedListQueries[key] = nil
            }
            return true
        case .search:
            return false
        }
    }
}
