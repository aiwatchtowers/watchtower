import Foundation
import WatchtowerCore

extension WorkbenchesViewModel {
    /// What the workbench page shows for owner presence (spec
    /// 2026-10-10-owner-asks-v2 Part 2.1), assuming its window is key and
    /// the Workbench tab is on screen — `AppState` checks both. The selected
    /// session is a terminal pane the layout shows: of two, the workbench's
    /// active session (the one focused last), else the first; a pane SwiftUI
    /// keeps alive off screen is not in the layout. The ask drawer beside
    /// that session's terminal is reported; it still counts as present.
    func ownerPresenceScreen() -> OwnerPresenceCenter.Screen {
        guard selectedStandaloneID == nil, let projectID = selectedWorkbench?.id else { return .other }
        let shown = layout(projectID: projectID).visiblePanes.compactMap { pane -> Int64? in
            if case let .session(id) = pane { return id }
            return nil
        }
        let active = activeSessionID(projectID: projectID)
        guard let session = shown.first(where: { $0 == active }) ?? shown.first else { return .other }
        let drawerOpen = asks.drawerAsk(projectID: projectID)?.sessionID == session
        return OwnerPresenceCenter.Screen(
            keyWindowShows: drawerOpen ? .workbenchSessionWithAskDrawer : .workbenchSession,
            selectedSession: session
        )
    }
}
