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
    /// An archived node (board #301) shows only with `showArchived`, whatever
    /// `showDone` says; a closed node leading to a shown archived one stays
    /// so the archived one keeps its place in the tree.
    ///
    /// A non-empty `query` (board #207, `WorkbenchBoardSearch`) keeps the
    /// targets it matches, their whole subtrees and the ancestors leading to
    /// them; done, dismissed and archived targets are searched too and nothing
    /// is collapsed, so a match is never hidden by any of them.
    ///
    /// A `scopeID` (spec 2026-10-06 Part 4, `WorkbenchBoardScope`) shows that
    /// group's subtree only, its children as the depth-0 rows; a stale one
    /// shows the whole board. A search inside a scope stays inside it and
    /// keeps what the same search on the whole board keeps there.
    package static func rows(
        _ roots: [WorkbenchBoardNode],
        collapsed: Set<Int>,
        showDone: Bool,
        showArchived: Bool = false,
        query: String = "",
        scopeID: Int? = nil
    ) -> [WorkbenchBoardRow] {
        var out: [WorkbenchBoardRow] = []
        let scope = WorkbenchBoardScope.resolve(scopeID, in: roots, showArchived: showArchived, query: query)
        let nodes = scope.node?.children ?? roots
        if let search = WorkbenchBoardSearch(query) {
            let pathMatched = WorkbenchBoardScope.pathMatches(scope.path, search)
            appendMatches(nodes, depth: 0, search: search, ancestorMatched: pathMatched, into: &out)
        } else {
            let filter = Filter(showDone: showDone, showArchived: showArchived)
            append(nodes, depth: 0, collapsed: collapsed, filter: filter, into: &out)
        }
        return out
    }

    /// Archived targets on the board, at any depth — the board's "Archive (K)".
    package static func archivedCount(_ nodes: [WorkbenchBoardNode]) -> Int {
        nodes.reduce(0) { $0 + ($1.archived ? 1 : 0) + archivedCount($1.children) }
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
        // Collapsing the target hides its subtree — with itself and its
        // current parent, the only places it cannot go.
        return rows(roots, collapsed: [node.target.id], showDone: true, showArchived: true)
            .filter { $0.id != targetID && $0.id != node.target.parentId }
    }

    private static func append(
        _ nodes: [WorkbenchBoardNode],
        depth: Int,
        collapsed: Set<Int>,
        filter: Filter,
        into out: inout [WorkbenchBoardRow]
    ) {
        for n in nodes where filter.shows(n) {
            out.append(WorkbenchBoardRow(node: n, depth: depth, hasChildren: !n.children.isEmpty))
            if !collapsed.contains(n.target.id) {
                append(n.children, depth: depth + 1, collapsed: collapsed, filter: filter, into: &out)
            }
        }
    }

    /// The list's Show done and Archive toggles, outside a search.
    private struct Filter {
        let showDone: Bool
        let showArchived: Bool

        func shows(_ n: WorkbenchBoardNode) -> Bool {
            if n.archived { return showArchived }
            return showDone || !WorkbenchBoardOutline.isClosed(n.target.status) || n.children.contains(where: shows)
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

    private static func isClosed(_ status: String) -> Bool {
        status == "done" || status == "dismissed"
    }
}

/// The group the Board pane is entered into (spec 2026-10-06 Part 4): any
/// target with children, at any depth, for both Kanban and List. Pure.
package enum WorkbenchBoardScope {
    /// The scope for a remembered `id`, with its path from the top-level
    /// target down to the scope itself (a depth-3 group has a 3-entry path).
    /// nil, a stale id (not on the board, now a leaf) or an id with an
    /// archived target on its path while "Archive" is off resolves to the
    /// board root: `(nil, [])`. A non-empty `query` counts as "Archive" on,
    /// as the search shows archived targets.
    package static func resolve(
        _ id: Int?,
        in roots: [WorkbenchBoardNode],
        showArchived: Bool,
        query: String = ""
    ) -> (node: WorkbenchBoardNode?, path: [WorkbenchBoardNode]) {
        let showArchived = showArchived || WorkbenchBoardSearch(query) != nil
        guard let id, let path = path(to: id, in: roots), let node = path.last, !node.children.isEmpty,
              showArchived || !path.contains(where: \.archived) else { return (nil, []) }
        return (node, path)
    }

    /// Whether `search` matches a target on the scope's `path` (the scope
    /// or an ancestor): then every leaf inside the scope matches too, as the
    /// same search on the whole board keeps them. False without a search.
    package static func pathMatches(_ path: [WorkbenchBoardNode], _ search: WorkbenchBoardSearch?) -> Bool {
        guard let search else { return false }
        return path.contains { search.matches($0.target) }
    }

    private static func path(to id: Int, in nodes: [WorkbenchBoardNode]) -> [WorkbenchBoardNode]? {
        for n in nodes {
            if n.target.id == id { return [n] }
            if let below = path(to: id, in: n.children) { return [n] + below }
        }
        return nil
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
