import Foundation
import WatchtowerCore

/// The sessions panel's keyboard (board #480, spec
/// 2026-10-12-sessions-panel-design §4.4): while the panel holds it
/// (`SessionsPanelKeyView`), ↑ ↓ move `panelCursor` over the rows the panel
/// shows, Return opens the cursor row, Esc hands the keyboard back to the
/// terminal on screen, ⌘⌫ deletes the cursor row — at once with Undo when
/// its agent is not working (`SessionDeletePolicy.isQuick`), else through
/// the confirmation — and ⌘Z undoes the pending batch. Moving the cursor
/// never opens or starts a session.
extension WorkbenchesViewModel {
    /// What ⌘⌫ on the cursor row did.
    enum PanelDeleteIntent: Equatable {
        /// Deleted at once; the toast offers Undo.
        case quick
        /// Its agent may be working: the page asks first.
        case confirm(TerminalSession)
    }

    /// Whether `session` is deleted with one ✕ or ⌘⌫, without a dialog.
    func isQuickDelete(_ session: TerminalSession) -> Bool {
        SessionDeletePolicy.isQuick(sessionState(session), isWorkbenchSession: session.projectID != nil)
    }

    /// Hands the keyboard to the sessions panel (a click on its empty
    /// space, the SESSIONS label or the group header, a ✕, the toast's
    /// Undo).
    func requestPanelKeyboard() {
        panelKeyboardSerial += 1
    }

    /// The panel took the keyboard: a cursor no longer listed (or none)
    /// starts on the session on screen, else on the first row.
    func enterPanelKeyboard(projectID: Int64) {
        let visible = panelSections(projectID: projectID).visibleOrder
        if let cursor = panelCursor, visible.contains(cursor) { return }
        if case let .session(id)? = visibleSession(projectID: projectID), visible.contains(id) {
            panelCursor = id
        } else {
            panelCursor = visible.first
        }
    }

    /// ↑ (`step` -1) / ↓ (+1) over the panel's rows, clamped at the ends.
    /// Only the highlight moves: no session opens or starts.
    func movePanelCursor(_ step: Int, projectID: Int64) {
        let visible = panelSections(projectID: projectID).visibleOrder
        guard !visible.isEmpty else { return }
        guard let cursor = panelCursor, let index = visible.firstIndex(of: cursor) else {
            panelCursor = step < 0 ? visible.last : visible.first
            return
        }
        panelCursor = visible[min(max(index + step, 0), visible.count - 1)]
    }

    /// Return: the cursor row opens like a click on it.
    func openAtPanelCursor(projectID: Int64) async {
        guard let id = listedPanelCursor(projectID: projectID) else { return }
        await showSession(id: id)
    }

    /// ⌘⌫ on the cursor row; nil when there is none.
    func deleteAtPanelCursor(projectID: Int64) async -> PanelDeleteIntent? {
        guard let id = listedPanelCursor(projectID: projectID),
              let session = session(id, projectID: projectID) else { return nil }
        guard isQuickDelete(session) else { return .confirm(session) }
        await delete(session)
        return .quick
    }

    /// Esc: the keyboard goes back to the terminal on screen. False when no
    /// session is on screen (the panel then just lets the keyboard go).
    func returnKeyboardToTerminal(projectID: Int64) -> Bool {
        guard case let .session(id)? = visibleSession(projectID: projectID) else { return false }
        terminalCenter?.requestKeyboardFocus(id)
        return true
    }

    /// Before `session`'s row leaves the panel (✕, ⌘⌫ or Delete…): the
    /// cursor moves to its neighbour so the owner can go on clearing.
    func movePanelCursorOff(_ session: TerminalSession) {
        guard let projectID = session.projectID else { return }
        let visible = panelSections(projectID: projectID).visibleOrder
        guard visible.contains(session.id) else { return }
        panelCursor = SessionPanelSections.panelNeighbour(of: session.id, in: visible)
    }

    /// The cursor, when the workbench's panel lists it.
    private func listedPanelCursor(projectID: Int64) -> Int64? {
        guard let cursor = panelCursor,
              panelSections(projectID: projectID).visibleOrder.contains(cursor) else { return nil }
        return cursor
    }
}
