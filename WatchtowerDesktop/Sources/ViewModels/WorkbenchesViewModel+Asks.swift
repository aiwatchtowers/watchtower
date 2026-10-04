import Foundation
import WatchtowerCore

/// Owner asks on the workbench page (spec 2026-10-03 Part 8): the stack,
/// the closed lists, the banner and the notices open an ask here.
extension WorkbenchesViewModel {
    /// Opens `askID` the way a stack row click does: the drawer on it and its
    /// session on screen — shown, never started (a stopped one offers
    /// Resume), so a click never launches an agent. An ask filed outside the
    /// app has no session: its drawer opens at the page's trailing edge.
    /// The drawer opens once the session is on screen (it closes whenever
    /// that session leaves it, `setLayout`). Returns false when the ask is
    /// gone or could not be read.
    @discardableResult
    func showAsk(_ askID: Int64, projectID: Int64) async -> Bool {
        if selectedWorkbenchID != projectID { drill(into: projectID) }
        guard let ask = await asks.lookUp(askID: askID, projectID: projectID) else { return false }
        if let sessionID = ask.sessionID {
            await revealTerminal(projectID: projectID, sessionID: sessionID)
            // A failed open already reports itself; no drawer beside nothing.
            guard layout(projectID: projectID).visiblePanes.contains(.session(sessionID)) else { return true }
        }
        asks.openDrawer(ask)
        return true
    }

    /// Opens the drawer by itself (board #364) on the oldest open ask of a
    /// session on the selected workbench's screen, when that session holds
    /// an ask the owner has not closed a drawer on — after each read of the
    /// asks, each layout change and a session pane widening. Never over a
    /// drawer already open, never expanded and never in a pane too narrow
    /// for it beside the terminal (the terminal stays visible and keeps the
    /// keyboard), and never moves the keyboard.
    func openNewAsk(projectID: Int64) {
        guard selectedWorkbenchID == projectID, asks.drawerAskIDs[projectID] == nil else { return }
        let onScreen = Set(layout(projectID: projectID).visiblePanes.compactMap { pane -> Int64? in
            if case let .session(id) = pane, !asks.crampedSessions.contains(id) { return id }
            return nil
        })
        guard let ask = asks.stack(projectID: projectID).askToOpen(
            sessionsOnScreen: onScreen, dismissed: asks.dismissedAskIDs[projectID] ?? []
        ) else { return }
        asks.drawerExpanded = false
        asks.openDrawer(ask)
    }

    /// Whether an expanded ask drawer covers `sessionID`'s terminal: its own
    /// session's, or every terminal of the page for an ask filed outside the
    /// app. A covered terminal never takes the keyboard (typing into an
    /// agent the owner cannot see, then Return, would submit).
    func isObscured(sessionID: Int64, projectID: Int64) -> Bool {
        guard asks.drawerExpanded, let ask = asks.drawerAsk(projectID: projectID) else { return false }
        return ask.sessionID == nil || ask.sessionID == sessionID
    }

    /// The drawer's "k of N ›": the next ask of the stack, switching to its
    /// session when another one filed it.
    func showNextAsk(after askID: Int64, projectID: Int64) async {
        guard let next = asks.stack(projectID: projectID).next(after: askID) else { return }
        await showAsk(next.id, projectID: projectID)
    }
}
