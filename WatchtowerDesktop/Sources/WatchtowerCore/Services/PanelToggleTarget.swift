import Foundation

/// What View → Show/Hide … (⌥⌘S) acts on: one chord, "show or hide this
/// screen's side panel", and one menu item, so no two menu items ever carry
/// the same key equivalent. The Workbench page wins while it has the keys
/// (its menu context's `canTogglePanel`); else the Inbox's folder rail while
/// the Inbox is on screen and no workbench window is key (a workbench
/// window under its Go to… palette never flips the rail of the main
/// window behind it); else nothing (the item is off). Pure.
package enum PanelToggleTarget: Equatable, Sendable {
    /// The Workbench page's sessions panel.
    case workbenchSessions(isShown: Bool)
    /// The Inbox's folder rail.
    case inboxFolders(isShown: Bool)

    /// The menu item's title.
    package var title: String {
        switch self {
        case let .workbenchSessions(isShown): isShown ? "Hide Sessions Panel" : "Show Sessions Panel"
        case let .inboxFolders(isShown): isShown ? "Hide Inbox Folders" : "Show Inbox Folders"
        }
    }

    package static func resolve(
        workbenchCanToggle: Bool,
        workbenchPanelShown: Bool,
        workbenchWindowIsKey: Bool,
        inboxOnScreen: Bool,
        inboxRailHidden: Bool
    ) -> Self? {
        if workbenchCanToggle { return .workbenchSessions(isShown: workbenchPanelShown) }
        if inboxOnScreen, !workbenchWindowIsKey { return .inboxFolders(isShown: !inboxRailHidden) }
        return nil
    }
}
