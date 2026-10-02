import Foundation
import WatchtowerCore

/// The ⌘K go-to palette (board #252): its results, and what ↵ and ⌘↵ open.
/// The data is read by `loadGoToPalette()` when it opens.
extension WorkbenchesViewModel {
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
    /// (`showSession(id:)` re-checks the page).
    func goTo(_ item: GoToItem) async {
        switch item {
        case let .workbench(row):
            await switchTo(workbenchID: row.id)
        case let .session(session, workbench):
            if workbench.id != selectedWorkbenchID { drill(into: workbench.id) }
            await showSession(id: session.id)
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
        let visible = layout(projectID: projectID).visiblePanes
        let focused = terminalCenter?.focusOrder.last.map(WorkspacePane.session).flatMap { visible.contains($0) ? $0 : nil }
        await open(session, placement: .beside(focused ?? visible.first ?? layout(projectID: projectID).primary))
    }
}
