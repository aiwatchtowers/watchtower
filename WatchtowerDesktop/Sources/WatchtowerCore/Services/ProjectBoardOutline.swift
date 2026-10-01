import Foundation

/// One visible line of the project board: a node plus its indentation.
package struct ProjectBoardRow: Identifiable {
    package let node: ProjectBoardNode
    package let depth: Int
    package let hasChildren: Bool
    package var id: Int { node.target.id }
}

/// Pure flattening of the board tree for the Board pane. No I/O.
package enum ProjectBoardOutline {
    /// Depth-first rows. A collapsed node keeps its row and hides its subtree.
    /// With `showDone == false` a done/dismissed node is hidden only when it has
    /// no open descendant — hiding a done feature must never hide its open task.
    package static func rows(
        _ roots: [ProjectBoardNode], collapsed: Set<Int>, showDone: Bool
    ) -> [ProjectBoardRow] {
        var out: [ProjectBoardRow] = []
        append(roots, depth: 0, collapsed: collapsed, showDone: showDone, into: &out)
        return out
    }

    package static func find(_ targetID: Int, in nodes: [ProjectBoardNode]) -> ProjectBoardNode? {
        for n in nodes {
            if n.target.id == targetID { return n }
            if let hit = find(targetID, in: n.children) { return hit }
        }
        return nil
    }

    private static func append(
        _ nodes: [ProjectBoardNode],
        depth: Int,
        collapsed: Set<Int>,
        showDone: Bool,
        into out: inout [ProjectBoardRow]
    ) {
        for n in nodes where showDone || hasOpenWork(n) {
            out.append(ProjectBoardRow(node: n, depth: depth, hasChildren: !n.children.isEmpty))
            if !collapsed.contains(n.target.id) {
                append(n.children, depth: depth + 1, collapsed: collapsed, showDone: showDone, into: &out)
            }
        }
    }

    private static func hasOpenWork(_ n: ProjectBoardNode) -> Bool {
        if !isClosed(n.target.status) { return true }
        return n.children.contains(where: hasOpenWork)
    }

    private static func isClosed(_ status: String) -> Bool {
        status == "done" || status == "dismissed"
    }
}
