import Foundation
import WatchtowerCore

extension WorkbenchesViewModel {
    /// What the workbench page shows for owner presence (spec
    /// 2026-10-10-owner-asks-v2 Part 2.1), assuming its window is key and
    /// the Workbench tab is on screen — `AppState` checks both. The selected
    /// session is a terminal pane the layout shows: of two, the one the
    /// owner focused last (a click into a terminal, a switch), else the
    /// first; a pane SwiftUI keeps alive off screen is not in the layout. An
    /// ask drawer on that session is reported, expanded over the terminal
    /// or beside it; either way it still counts as present (the policy does
    /// not tell them apart). A closed drawer is no drawer.
    func ownerPresenceScreen() -> OwnerPresenceCenter.Screen {
        guard selectedStandaloneID == nil, let projectID = selectedWorkbench?.id else { return .other }
        let shown = layout(projectID: projectID).visiblePanes.compactMap { pane -> Int64? in
            if case let .session(id) = pane { return id }
            return nil
        }
        let focused = terminalCenter?.focusOrder.last(where: shown.contains)
        guard let session = focused ?? shown.first else { return .other }
        let drawerOpen = asks.drawerAsk(projectID: projectID)?.sessionID == session
        return OwnerPresenceCenter.Screen(
            keyWindowShows: drawerOpen ? .workbenchSessionWithAskDrawer : .workbenchSession,
            selectedSession: session
        )
    }
}
