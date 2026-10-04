import Foundation

/// The Board pane's kanban mode: the board's leaf targets in one column per
/// status. Pure; no I/O.
///
/// Only leaves are cards — a parent's status is derived from its children by
/// the PROJ-05 rollup triggers, so moving a parent would be undone by its next
/// child change. Within a column cards sort by priority, then id (the status
/// part of `WorkbenchBoardOrder` is constant there); the Done column instead
/// lists the most recently updated first, because with "Show done" off it
/// keeps only the latest `doneCap` and "latest" is what the owner looks for.
/// Archived leaves (board #301) are cards only with "Archive" on, in the Done
/// and Dismissed columns, never capped.
package struct WorkbenchBoardKanban {
    /// Status of the catch-all column for a status this build does not know.
    package static let otherStatus = "__other__"
    /// Done cards shown while "Show done" is off.
    package static let doneCap = 10

    package struct Card: Identifiable {
        package let node: WorkbenchBoardNode
        /// The parent chain from the top-level target down, " › "-joined;
        /// empty for a top-level leaf.
        package let breadcrumb: String
        package var id: Int { node.target.id }
        /// The card as a flat board row: no indent, no chevron.
        package var row: WorkbenchBoardRow { WorkbenchBoardRow(node: node, depth: 0, hasChildren: false) }
    }

    package struct Column: Identifiable {
        package let status: String
        package let title: String
        package let cards: [Card]
        /// Cards left out of `cards` (the Done cap), shown as "N more".
        package let hiddenCount: Int
        /// Dropping a card here sets its status to `status`; the Other column
        /// has no single status to set.
        package var acceptsDrops: Bool { status != WorkbenchBoardKanban.otherStatus }
        package var id: String { status }
    }

    /// A parent-filter menu entry: a top-level target with leaf descendants.
    package struct FilterOption: Identifiable, Equatable {
        package let id: Int
        package let title: String
    }

    package let columns: [Column]
    package let filterOptions: [FilterOption]
    /// The filter actually applied: nil (All) when the requested one is not
    /// among `filterOptions` (deleted, or no longer a parent).
    package let filterRootID: Int?
    /// Archived leaves under the applied filter, whatever the toggles and
    /// the search: the cards "Archive" adds, Kanban's "Archive (K)".
    package let archivedCardCount: Int

    /// A non-empty `query` (`WorkbenchBoardSearch`) keeps the leaves it
    /// matches and the leaves under a parent it matches, and shows the done,
    /// dismissed and archived ones as if "Show done" and "Archive" were on.
    /// With "Archive" on and "Show done" off, the Dismissed column holds only
    /// archived cards.
    package init(
        _ roots: [WorkbenchBoardNode],
        filterRootID: Int?,
        showDone: Bool,
        showArchived: Bool = false,
        query: String = ""
    ) {
        let search = WorkbenchBoardSearch(query)
        let showDone = showDone || search != nil
        let showArchived = showArchived || search != nil
        let options = roots.filter { !$0.children.isEmpty && (showArchived || !$0.archived) }.map {
            FilterOption(id: $0.target.id, title: WorkbenchBoardCard.title($0.target.text))
        }
        let applied = filterRootID.flatMap { id in options.contains { $0.id == id } ? id : nil }
        let scope = applied.map { id in roots.filter { $0.target.id == id } } ?? roots

        var collected: [Card] = []
        Self.collectLeaves(scope, chain: [], search: search, ancestorMatched: false, into: &collected)
        let leaves = collected.filter { card in
            card.node.archived ? showArchived : (showDone || card.node.target.status != "dismissed")
        }

        var statuses = ["todo", "in_progress", "in_review", "blocked", "done"]
        if showDone || showArchived { statuses.append("dismissed") }
        var columns = statuses.map { status in
            Self.column(status, cards: leaves.filter { $0.node.target.status == status }, showDone: showDone)
        }
        let known = Set(WorkbenchBoardCard.editableStatuses)
        let other = leaves.filter { !known.contains($0.node.target.status) }
        if !other.isEmpty {
            columns.append(Self.column(Self.otherStatus, cards: other, showDone: showDone))
        }

        self.columns = columns
        self.filterOptions = options
        self.filterRootID = applied
        self.archivedCardCount = Self.archivedLeafCount(scope)
    }

    /// Whether `id` is a card shown on this board. A drop accepts only these:
    /// the drop payload is plain text, so a number dragged in from elsewhere
    /// (or a parent's id) must never move a target.
    package func showsCard(_ id: Int) -> Bool {
        columns.contains { $0.cards.contains { $0.id == id } }
    }

    private static func column(_ status: String, cards: [Card], showDone: Bool) -> Column {
        let title = status == otherStatus ? "Other" : WorkbenchBoardCard.statusLabel(status)
        guard status == "done" else {
            return Column(status: status, title: title, cards: cards.sorted(by: byPriorityThenID), hiddenCount: 0)
        }
        let recent = cards.filter { !$0.node.archived }.sorted(by: byRecency)
        let kept = showDone ? recent : Array(recent.prefix(doneCap))
        let shown = (kept + cards.filter(\.node.archived)).sorted(by: byRecency)
        return Column(status: status, title: title, cards: shown, hiddenCount: recent.count - kept.count)
    }

    private static func archivedLeafCount(_ nodes: [WorkbenchBoardNode]) -> Int {
        nodes.reduce(0) { count, n in
            count + (n.children.isEmpty ? (n.archived ? 1 : 0) : archivedLeafCount(n.children))
        }
    }

    private static func byRecency(_ lhs: Card, _ rhs: Card) -> Bool {
        let l = lhs.node.target, r = rhs.node.target
        return l.updatedAt != r.updatedAt ? l.updatedAt > r.updatedAt : l.id > r.id
    }

    private static func byPriorityThenID(_ lhs: Card, _ rhs: Card) -> Bool {
        let l = lhs.node.target, r = rhs.node.target
        return (WorkbenchBoardOrder.priorityRank(l.priority), l.id) < (WorkbenchBoardOrder.priorityRank(r.priority), r.id)
    }

    /// With a `search`, a leaf is kept when it or an ancestor matches.
    private static func collectLeaves(
        _ nodes: [WorkbenchBoardNode],
        chain: [String],
        search: WorkbenchBoardSearch?,
        ancestorMatched: Bool,
        into out: inout [Card]
    ) {
        for n in nodes {
            let matched = ancestorMatched || (search.map { $0.matches(n.target) } ?? true)
            if n.children.isEmpty {
                if matched { out.append(Card(node: n, breadcrumb: chain.joined(separator: " › "))) }
            } else {
                collectLeaves(n.children, chain: chain + [WorkbenchBoardCard.title(n.target.text)],
                              search: search, ancestorMatched: matched, into: &out)
            }
        }
    }
}

/// How the Board pane shows the board.
package enum WorkbenchBoardMode: String, CaseIterable {
    case list
    case kanban
}

/// Per-project Board view state in UserDefaults — view state, not data, so it
/// never touches the database.
package struct WorkbenchBoardPreferences {
    private let defaults: UserDefaults
    private let modeKey: String
    private let filterKey: String

    package init(workbenchID: Int64, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The `projects.` prefix predates the Workbench rename; persisted, so kept (spec 2026-10-02 A1).
        modeKey = "projects.boardMode.\(workbenchID)"
        filterKey = "projects.boardKanbanFilter.\(workbenchID)"
    }

    /// Defaults to List; an unknown stored value reads as List too.
    package var mode: WorkbenchBoardMode {
        get { defaults.string(forKey: modeKey).flatMap(WorkbenchBoardMode.init(rawValue:)) ?? .list }
        nonmutating set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    /// The kanban parent filter's root target id; nil = All. A stale id is
    /// resolved to All by `WorkbenchBoardKanban`, not here.
    package var kanbanFilterRootID: Int? {
        get { defaults.object(forKey: filterKey) == nil ? nil : defaults.integer(forKey: filterKey) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: filterKey) } else { defaults.removeObject(forKey: filterKey) }
        }
    }
}
