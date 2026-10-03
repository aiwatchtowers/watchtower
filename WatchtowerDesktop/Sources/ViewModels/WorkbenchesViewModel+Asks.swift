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
