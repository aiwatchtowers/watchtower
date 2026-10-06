import Foundation

/// A group's "N of M done" (spec 2026-10-06 Part 3) — the side panel, the
/// path bar and the lane header alike: over the group's leaves at every
/// depth, a nested group counted through its own leaves. Archived leaves
/// count only with the board's Archive toggle on (the toggle itself, not a
/// search). A dismissed leaf is in the breakdown but not in `total` — out
/// of scope, not unfinished work.
package struct WorkbenchGroupSummary: Equatable {
    package struct StatusCount: Equatable {
        package let status: String
        package let count: Int

        package init(status: String, count: Int) {
            self.status = status
            self.count = count
        }
    }

    package let done: Int
    package let total: Int
    /// Leaves per status in the board's status order, a status this build
    /// does not know after them; statuses with no leaf are left out.
    package let breakdown: [StatusCount]

    package init(_ group: WorkbenchBoardNode, showArchived: Bool) {
        self.init(over: group.children, showArchived: showArchived)
    }

    /// Over `nodes` and their leaves: a group's children, or the loose
    /// leaves a lane without a group holds (No group, a scope's Tasks).
    package init(over nodes: [WorkbenchBoardNode], showArchived: Bool) {
        let leaves = Self.leaves(nodes, showArchived: showArchived)
        done = leaves.filter { $0.target.status == "done" }.count
        total = leaves.filter { $0.target.status != "dismissed" }.count
        let counts = Dictionary(grouping: leaves, by: \.target.status).mapValues(\.count)
        let known = WorkbenchBoardCard.editableStatuses
        let unknown = counts.keys.filter { !known.contains($0) }.sorted()
        breakdown = (known + unknown).compactMap { status in
            counts[status].map { StatusCount(status: status, count: $0) }
        }
    }

    private static func leaves(_ nodes: [WorkbenchBoardNode], showArchived: Bool) -> [WorkbenchBoardNode] {
        nodes.filter { showArchived || !$0.archived }.flatMap {
            $0.children.isEmpty ? [$0] : leaves($0.children, showArchived: showArchived)
        }
    }
}

/// The group panel's SUB-TASKS tree (spec 2026-10-06 Part 3): the group's
/// children depth-first, as `WorkbenchBoardOutline` rows rooted at the
/// group. Under each parent the open sub-tasks come first in board order;
/// the closed ones (done or dismissed with nothing open below) fold into one
/// "✓ N closed" row after them, which opens in place. A collapsed nested
/// group keeps its row and hides its subtree. Archived sub-tasks show only
/// with the board's Archive toggle on. Both fold sets are the panel's own.
package enum WorkbenchSubtaskTree {
    /// The "✓ N closed" row of `parentID`'s closed children.
    package struct ClosedFold: Equatable {
        package let parentID: Int
        package let depth: Int
        package let count: Int
        package let unfolded: Bool
    }

    package enum Row: Identifiable {
        case target(WorkbenchBoardRow)
        case closed(ClosedFold)

        package var id: String {
            switch self {
            case let .target(row): "target-\(row.id)"
            case let .closed(fold): "closed-\(fold.parentID)"
            }
        }
    }

    /// - Parameters:
    ///   - collapsed: nested groups folded in the panel.
    ///   - unfoldedClosed: parents whose "✓ N closed" row is open.
    package static func rows(
        of group: WorkbenchBoardNode,
        collapsed: Set<Int>,
        unfoldedClosed: Set<Int>,
        showArchived: Bool
    ) -> [Row] {
        var out: [Row] = []
        let rules = Rules(collapsed: collapsed, unfoldedClosed: unfoldedClosed, showArchived: showArchived)
        append(group.children, parentID: group.target.id, depth: 0, rules: rules, into: &out)
        return out
    }

    private struct Rules {
        let collapsed: Set<Int>
        let unfoldedClosed: Set<Int>
        let showArchived: Bool

        func shows(_ node: WorkbenchBoardNode) -> Bool { showArchived || !node.archived }

        /// Done or dismissed, and so is everything shown below it.
        func isSettled(_ node: WorkbenchBoardNode) -> Bool {
            ["done", "dismissed"].contains(node.target.status) && node.children.filter(shows).allSatisfy(isSettled)
        }
    }

    private static func append(
        _ nodes: [WorkbenchBoardNode],
        parentID: Int,
        depth: Int,
        rules: Rules,
        into out: inout [Row]
    ) {
        let shown = nodes.filter(rules.shows)
        let closed = shown.filter(rules.isSettled)
        for node in shown where !rules.isSettled(node) {
            appendNode(node, depth: depth, rules: rules, into: &out)
        }
        guard !closed.isEmpty else { return }
        let unfolded = rules.unfoldedClosed.contains(parentID)
        out.append(.closed(ClosedFold(parentID: parentID, depth: depth, count: closed.count, unfolded: unfolded)))
        if unfolded {
            for node in closed { appendNode(node, depth: depth, rules: rules, into: &out) }
        }
    }

    private static func appendNode(_ node: WorkbenchBoardNode, depth: Int, rules: Rules, into out: inout [Row]) {
        out.append(.target(WorkbenchBoardRow(node: node, depth: depth, hasChildren: !node.children.isEmpty)))
        if !rules.collapsed.contains(node.target.id) {
            append(node.children, parentID: node.target.id, depth: depth + 1, rules: rules, into: &out)
        }
    }
}
