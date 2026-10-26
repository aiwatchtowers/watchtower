import Foundation
import WatchtowerCore

/// A screen that covers a workbench's workspace area while it is open — the
/// Clean Up screen (board #1107) or Agent Settings (board #1150). One at a
/// time per workbench; page state in memory only, never a `WorkspacePane`
/// or a `WorkspaceLayout` value.
enum WorkbenchPageScreen: Equatable {
    case cleanUp
    case agentSettings

    /// The title row's crumb (`<title> ✕`).
    var title: String {
        switch self {
        case .cleanUp: "Clean Up"
        case .agentSettings: "Agent Settings"
        }
    }
}

extension WorkbenchesViewModel {
    /// The screen covering workbench `projectID`'s workspace, if any.
    func pageScreen(projectID: Int64) -> WorkbenchPageScreen? {
        if cleanupScreenOpen(projectID: projectID) { return .cleanUp }
        if agentSettingsScreens.contains(projectID) { return .agentSettings }
        return nil
    }

    /// Whether a screen covers workbench `projectID`'s workspace: no
    /// terminal behind it takes the keyboard, no title-row tab is on.
    func pageCovered(projectID: Int64) -> Bool {
        pageScreen(projectID: projectID) != nil
    }

    /// The ⋯ menu's Agent Settings…: the screen covers the workspace, in
    /// place of a Clean Up screen that was open.
    func openAgentSettingsScreen(projectID: Int64) {
        closeCleanupScreen(projectID: projectID)
        agentSettingsScreens.insert(projectID)
    }

    /// The crumb's ✕, a title-row segment, a session put on screen: the
    /// workspace shows again as it was.
    func closePageScreen(projectID: Int64) {
        closeCleanupScreen(projectID: projectID)
        agentSettingsScreens.remove(projectID)
    }
}
