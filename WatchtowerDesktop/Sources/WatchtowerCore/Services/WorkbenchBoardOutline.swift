import Foundation

/// One visible line of the project board: a node plus its indentation.
package struct WorkbenchBoardRow: Identifiable {
    package let node: WorkbenchBoardNode
    package let depth: Int
    package let hasChildren: Bool
    package var id: Int { node.target.id }
}

/// Pure flattening of the board tree for the Board pane. No I/O.
package enum WorkbenchBoardOutline {
    /// Depth-first rows. A collapsed node keeps its row and hides its subtree.
    /// With `showDone == false` a done/dismissed node is hidden only when it has
    /// no open descendant — hiding a done feature must never hide its open task.
    package static func rows(
        _ roots: [WorkbenchBoardNode], collapsed: Set<Int>, showDone: Bool
    ) -> [WorkbenchBoardRow] {
        var out: [WorkbenchBoardRow] = []
        append(roots, depth: 0, collapsed: collapsed, showDone: showDone, into: &out)
        return out
    }

    package static func find(_ targetID: Int, in nodes: [WorkbenchBoardNode]) -> WorkbenchBoardNode? {
        for n in nodes {
            if n.target.id == targetID { return n }
            if let hit = find(targetID, in: n.children) { return hit }
        }
        return nil
    }

    private static func append(
        _ nodes: [WorkbenchBoardNode],
        depth: Int,
        collapsed: Set<Int>,
        showDone: Bool,
        into out: inout [WorkbenchBoardRow]
    ) {
        for n in nodes where showDone || hasOpenWork(n) {
            out.append(WorkbenchBoardRow(node: n, depth: depth, hasChildren: !n.children.isEmpty))
            if !collapsed.contains(n.target.id) {
                append(n.children, depth: depth + 1, collapsed: collapsed, showDone: showDone, into: &out)
            }
        }
    }

    private static func hasOpenWork(_ n: WorkbenchBoardNode) -> Bool {
        if !isClosed(n.target.status) { return true }
        return n.children.contains(where: hasOpenWork)
    }

    private static func isClosed(_ status: String) -> Bool {
        status == "done" || status == "dismissed"
    }
}
