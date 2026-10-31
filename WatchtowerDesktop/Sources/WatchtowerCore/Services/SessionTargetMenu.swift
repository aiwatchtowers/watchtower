import Foundation

/// The session row's **Session Target ▸** submenu (board #1352): its texts
/// and the items built from the board tree. Pure; the view draws the items
/// and the view model runs `watchtower workbench session-target`.
package enum SessionTargetMenu {
    package static let title = "Session Target"
    package static let noneTitle = "None — Count What It Touched"

    /// The CLI's refusal as the menu shows it.
    package static func failureLine(_ error: String) -> String {
        "Couldn't change the session target: \(error)"
    }

    package indirect enum Item: Equatable {
        case none(checked: Bool)
        /// A target with `children` is a submenu whose first item is the
        /// target itself (as in **Move to…**).
        case target(id: Int64, title: String, checked: Bool, children: [Self])
    }

    /// **None** first, then the board tree. Archived and dismissed targets
    /// are left out with their subtrees (an archived node's subtree is
    /// archived too). `current` is the session's bound target, nil = none.
    package static func items(roots: [WorkbenchBoardNode], current: Int64?) -> [Item] {
        [.none(checked: current == nil)] + targetItems(roots, current: current)
    }

    private static func targetItems(_ nodes: [WorkbenchBoardNode], current: Int64?) -> [Item] {
        nodes.compactMap { node in
            guard !node.archived, node.target.status != "dismissed" else { return nil }
            let id = Int64(node.target.id)
            let name = node.target.text
            let children = targetItems(node.children, current: current)
            if children.isEmpty {
                return .target(id: id, title: name, checked: id == current, children: [])
            }
            let itself = Item.target(id: id, title: name, checked: id == current, children: [])
            return .target(id: id, title: name, checked: false, children: [itself] + children)
        }
    }
}
