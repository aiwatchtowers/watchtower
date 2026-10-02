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
    ///
    /// A non-empty `query` (board #207, `WorkbenchBoardSearch`) keeps the
    /// targets it matches, their whole subtrees and the ancestors leading to
    /// them; done and dismissed targets are searched too and nothing is
    /// collapsed, so a match is never hidden by either.
    package static func rows(
        _ roots: [WorkbenchBoardNode], collapsed: Set<Int>, showDone: Bool, query: String = ""
    ) -> [WorkbenchBoardRow] {
        var out: [WorkbenchBoardRow] = []
        if let search = WorkbenchBoardSearch(query) {
            appendMatches(roots, depth: 0, search: search, ancestorMatched: false, into: &out)
        } else {
            append(roots, depth: 0, collapsed: collapsed, showDone: showDone, into: &out)
        }
        return out
    }

    package static func find(_ targetID: Int, in nodes: [WorkbenchBoardNode]) -> WorkbenchBoardNode? {
        for n in nodes {
            if n.target.id == targetID { return n }
            if let hit = find(targetID, in: n.children) { return hit }
        }
        return nil
    }

    /// Whether the board may move `targetID` under `parentID` (nil = the
    /// top level, board #186): both on this board, the parent neither the
    /// target nor inside its subtree, and not where it already is. The DB
    /// write re-checks all of it (`WorkbenchQueries.moveTarget`).
    package static func canMove(_ targetID: Int, under parentID: Int?, in roots: [WorkbenchBoardNode]) -> Bool {
        guard let node = find(targetID, in: roots) else { return false }
        guard let parentID else { return node.target.parentId != nil }
        return node.target.parentId != parentID
            && find(parentID, in: roots) != nil
            && find(parentID, in: [node]) == nil
    }

    /// The "Move to…" menu for `targetID`: every board target it may move
    /// under, depth-first with its depth.
    package static func moveDestinations(for targetID: Int, in roots: [WorkbenchBoardNode]) -> [WorkbenchBoardRow] {
        guard let node = find(targetID, in: roots) else { return [] }
        return rows(roots, collapsed: [node.target.id], showDone: true)
            .filter { $0.id != targetID && $0.id != node.target.parentId }
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

    private static func appendMatches(
        _ nodes: [WorkbenchBoardNode],
        depth: Int,
        search: WorkbenchBoardSearch,
        ancestorMatched: Bool,
        into out: inout [WorkbenchBoardRow]
    ) {
        for n in nodes {
            let matched = ancestorMatched || search.matches(n.target)
            guard matched || search.matchesBelow(n) else { continue }
            out.append(WorkbenchBoardRow(node: n, depth: depth, hasChildren: !n.children.isEmpty))
            appendMatches(n.children, depth: depth + 1, search: search, ancestorMatched: matched, into: &out)
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

/// The Board pane's search (board #207): `#163` finds target 163 only; a bare
/// number finds that target or a title/intent containing it; any other text
/// matches the title or intent, ignoring case and diacritics. A blank query is
/// no search (`init` returns nil).
package struct WorkbenchBoardSearch {
    private let text: String
    private let id: Int?
    private let idOnly: Bool

    package init?(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let digits = q.hasPrefix("#") ? String(q.dropFirst()) : q
        let isNumber = !digits.isEmpty && digits.allSatisfy(\.isASCIIDigit)
        text = q
        id = isNumber ? Int(digits) : nil
        idOnly = isNumber && q.hasPrefix("#")
    }

    package func matches(_ target: Target) -> Bool {
        if let id, target.id == id { return true }
        if idOnly { return false }
        return target.text.localizedStandardContains(text) || target.intent.localizedStandardContains(text)
    }

    /// Whether any descendant of `node` matches.
    package func matchesBelow(_ node: WorkbenchBoardNode) -> Bool {
        node.children.contains { matches($0.target) || matchesBelow($0) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
