import Foundation

/// What View → "Go to Item" (⌘1…⌘9) and View → Back (⌘[) act on (spec
/// 2026-10-26 §4, §5.4). One set of items serves two tabs, so two menu
/// items never race for one key: the Workbench page publishes its menu
/// context, the Chats tab its own, and at most one of them is set for the
/// key window. Pure.
package enum ItemShortcutTarget: Equatable, Sendable {
    /// ⌘n opens session n of the sessions panel.
    case workbenchSessions
    /// ⌘n opens chat n of the Chats panel.
    case chatRows

    /// What ⌘[ does.
    package enum Back: Equatable, Sendable {
        /// The focused Workchat pane's open subagent pops (#711).
        case popSubagent
        /// The workbench page goes back to the workbench list.
        case showAllWorkbenches
        /// The Chats panel goes back from a project to All chats.
        case showAllChats
    }

    /// The Workbench tab's state, from its menu context.
    package struct Workbench: Equatable, Sendable {
        /// A workbench page is shown and no Go to… palette is open.
        package let canUseSessionKeys: Bool
        /// The workbench context's own `backAction(popAvailable:)`.
        package let back: Back?

        package init(canUseSessionKeys: Bool, back: Back?) {
            self.canUseSessionKeys = canUseSessionKeys
            self.back = back
        }
    }

    /// The Chats tab's state, from its menu context.
    package struct Chats: Equatable, Sendable {
        /// No search sheet or rename field is taking the keys.
        package let canUseRowKeys: Bool
        /// The panel shows one project's chats.
        package let projectSelected: Bool

        package init(canUseRowKeys: Bool, projectSelected: Bool) {
            self.canUseRowKeys = canUseRowKeys
            self.projectSelected = projectSelected
        }
    }

    package struct Resolution: Equatable, Sendable {
        /// What ⌘1…⌘9 open; nil = the items are off.
        package let items: ItemShortcutTarget?
        /// What ⌘[ does; nil = Back is off.
        package let back: Back?

        package init(items: ItemShortcutTarget?, back: Back?) {
            self.items = items
            self.back = back
        }
    }

    /// The Workbench page → its sessions and its own back action (the
    /// subagent pop first); the Chats tab → its rows, and back to All chats
    /// while a project is selected; anything else (another tab) → both off.
    package static func resolve(workbench: Workbench?, chats: Chats?) -> Resolution {
        if let workbench {
            return Resolution(items: workbench.canUseSessionKeys ? .workbenchSessions : nil, back: workbench.back)
        }
        if let chats, chats.canUseRowKeys {
            return Resolution(items: .chatRows, back: chats.projectSelected ? .showAllChats : nil)
        }
        return Resolution(items: nil, back: nil)
    }
}
