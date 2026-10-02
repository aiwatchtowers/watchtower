import Foundation
import GRDB
import WatchtowerCore

/// The ⌘K go-to palette (board #252): its data, its results, and what ↵
/// and ⌘↵ open.
extension WorkbenchesViewModel {
    /// ⌘K: every workbench's sessions, the switcher's rows, and the page's
    /// own list (the first section keeps the panel's order).
    func loadGoToPalette() async {
        if let projectID = selectedWorkbenchID { await loadSessions(projectID: projectID) }
        await loadSwitcherSummaries()
        do {
            goToSessions = try await dbPool.read { try TerminalSessionQueries.fetchAllWorkbenchSessions($0) }
            goToError = nil
        } catch {
            goToError = "Could not load sessions: \(error.localizedDescription)"
        }
    }

    /// The palette's sections for `query` (`GoToRanking`): the page's own
    /// sessions in the panel's order first, when a workbench page is shown.
    func goToSections(query: String) -> [GoToSection] {
        let current = selectedWorkbenchID.map {
            GoToRanking.Current(workbenchID: $0, orderedSessions: orderedSessions(projectID: $0))
        }
        return GoToRanking.results(query: query, current: current, sessions: goToSessions, workbenches: switcherSummaries)
    }

    /// ↵: a workbench row switches to it (`switchTo`); a session opens like
    /// a panel click, in its own workbench — another one is drilled into
    /// first. A move to another page while its list is read opens nothing
    /// (`showSession(id:)` re-checks the page). The keyboard then goes back
    /// into the terminal in focus there.
    func goTo(_ item: GoToItem) async {
        switch item {
        case let .workbench(row):
            await switchTo(workbenchID: row.id)
            focusTerminal(projectID: row.id)
        case let .session(session, workbench):
            if workbench.id != selectedWorkbenchID { drill(into: workbench.id) }
            await showSession(id: session.id)
            focusTerminal(projectID: workbench.id)
        }
    }

    /// ⌘↵ on a session of the workbench on screen: it goes beside the
    /// focused pane — a single pane splits with it second, a split replaces
    /// the other pane, one already on screen stays where it is. Either way it
    /// is opened like a panel click (focused; one not running starts). A
    /// session of another workbench is not split in (the palette opens it
    /// like ↵).
    func openInSplit(session: TerminalSession) async {
        guard let projectID = selectedWorkbenchID, session.projectID == projectID else { return }
        let current = layout(projectID: projectID)
        // The focused session's pane, else the first pane on screen.
        var kept = current.expanded ?? current.primary
        if let focused = terminalCenter?.focusOrder.last, current.visiblePanes.contains(.session(focused)) {
            kept = .session(focused)
        }
        await open(session, placement: .beside(kept))
        focusTerminal(projectID: projectID)
    }

    /// The palette took the keyboard: once it is closed and the layout
    /// placed, the focused session's terminal gets it back — when that
    /// workbench is still on screen with the session in a visible pane
    /// (`TerminalCenter.requestKeyboardFocus`; a terminal already attached
    /// moves no focus by itself).
    private func focusTerminal(projectID: Int64) {
        guard selectedWorkbenchID == projectID, let id = terminalCenter?.focusOrder.last,
              layout(projectID: projectID).visiblePanes.contains(.session(id)) else { return }
        terminalCenter?.requestKeyboardFocus(id)
    }
}
