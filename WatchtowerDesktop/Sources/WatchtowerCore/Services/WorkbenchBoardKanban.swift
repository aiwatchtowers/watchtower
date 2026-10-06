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

    /// One lane of the "Lanes: By group" layout (spec 2026-10-06 Part 2): a
    /// top-level group's leaves, or the top-level leaves under No group, in
    /// the board's columns. The Done column holds every done card, never
    /// capped; folding it is the view's (`doneFolded`, `cards(_:unfolded:)`).
    package struct Lane: Identifiable {
        /// Done leaves over the leaves that still count (dismissed ones do
        /// not), archived included and whatever the filters: the group's own
        /// progress, not the cards on screen. `total` may be 0.
        package struct Progress: Equatable {
            package let done: Int
            package let total: Int
        }

        /// The lane's group; nil for the No group lane.
        package let root: WorkbenchBoardNode?
        package let title: String
        /// The board's columns, filled with this lane's cards only.
        package let columns: [Column]
        package let progress: Progress
        /// Done renders as one "✓ N done — show" row: unless "Show done" is
        /// on or a search is active.
        package let doneFolded: Bool
        /// The live done cards the fold stands for. Archived done cards are
        /// never folded, as the None layout's cap never trims them.
        package let doneCount: Int

        /// The root's id; the No group lane folds under id 0.
        package var id: Int { root?.target.id ?? 0 }

        /// What `column` shows: with the Done fold closed, its live done
        /// cards are left out.
        package func cards(_ column: Column, unfolded: Bool) -> [Card] {
            guard column.status == "done", doneFolded, !unfolded else { return column.cards }
            return column.cards.filter(\.node.archived)
        }

        /// Whether `id` is a card of this lane, folded or not. A drop into
        /// this lane's columns accepts only these.
        package func showsCard(_ id: Int) -> Bool {
            columns.contains { $0.cards.contains { $0.id == id } }
        }
    }

    /// The "Lanes: None" layout: the whole board in one set of columns.
    package let columns: [Column]
    /// The "Lanes: By group" layout, in `WorkbenchBoardOrder` with No group
    /// last. A lane with nothing to show is left out, except one whose root
    /// is open while the search is empty (the view says "No open tasks").
    package let lanes: [Lane]
    /// Per column status, the cards in that column over `lanes`: the totals
    /// row above the lanes.
    package let totals: [String: Int]
    package let filterOptions: [FilterOption]
    /// The filter actually applied: nil (All) when the requested one is not
    /// among `filterOptions` (deleted, or no longer a parent).
    package let filterRootID: Int?
    /// Archived leaves under the filter "Archive" on would apply, whatever
    /// the toggles and the search: the cards "Archive" adds, Kanban's
    /// "Archive (K)".
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
        let options = Self.filterOptions(roots, showArchived: showArchived)
        let applied = Self.applied(filterRootID, among: options)
        let scope = Self.scope(roots, applied)

        var collected: [Card] = []
        Self.collectLeaves(scope, chain: [], search: search, ancestorMatched: false, into: &collected)
        let leaves = collected.filter { Self.isShown($0, showDone: showDone, showArchived: showArchived) }

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
        let lanes = Self.lanes(scope, LaneRules(
            statuses: columns.map(\.status), search: search, showDone: showDone, showArchived: showArchived
        ))
        self.lanes = lanes
        self.totals = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column.status, lanes.reduce(0) { sum, lane in
                sum + (lane.columns.first { $0.status == column.status }?.cards.count ?? 0)
            })
        })
        self.filterOptions = options
        self.filterRootID = applied
        // Counted over what "Archive" on shows: a remembered filter on an
        // archived root applies only then.
        let archiveScope = Self.scope(roots, Self.applied(filterRootID, among: Self.filterOptions(roots, showArchived: true)))
        self.archivedCardCount = Self.archivedLeafCount(archiveScope)
    }

    /// Whether `id` is a card shown on this board. A drop accepts only these:
    /// the drop payload is plain text, so a number dragged in from elsewhere
    /// (or a parent's id) must never move a target.
    package func showsCard(_ id: Int) -> Bool {
        columns.contains { $0.cards.contains { $0.id == id } }
    }

    private static func isShown(_ card: Card, showDone: Bool, showArchived: Bool) -> Bool {
        card.node.archived ? showArchived : (showDone || card.node.target.status != "dismissed")
    }

    /// The board's filters as every lane applies them. `statuses` are the
    /// board's columns, so every lane lines up under the totals row.
    private struct LaneRules {
        let statuses: [String]
        let search: WorkbenchBoardSearch?
        let showDone: Bool
        let showArchived: Bool
    }

    /// Lays out `roots`: each one with children is a lane, the leaves among
    /// them share the No group lane.
    private static func lanes(_ roots: [WorkbenchBoardNode], _ rules: LaneRules) -> [Lane] {
        let groups = Dictionary(uniqueKeysWithValues: roots.filter { !$0.children.isEmpty }.map { ($0.target.id, $0) })
        let ordered = WorkbenchBoardOrder.sorted(groups.values.map(\.target)).compactMap { groups[$0.id] }
        var lanes = ordered.map { root in
            lane(root: root, title: WorkbenchBoardCard.title(root.target.text), nodes: root.children,
                 ancestorMatched: rules.search?.matches(root.target) ?? false, rules: rules)
        }
        let loose = roots.filter(\.children.isEmpty)
        if !loose.isEmpty {
            lanes.append(lane(root: nil, title: "No group", nodes: loose, ancestorMatched: false, rules: rules))
        }
        return lanes.filter { lane in
            let shows = lane.columns.contains { !lane.cards($0, unfolded: false).isEmpty }
            let rootOpen = lane.root.map { !["done", "dismissed"].contains($0.target.status) } ?? false
            return shows || (rules.search == nil && rootOpen)
        }
    }

    /// One lane through the board's own collector, visibility rule and
    /// column builder; the breadcrumb starts below the lane root.
    private static func lane(
        root: WorkbenchBoardNode?,
        title: String,
        nodes: [WorkbenchBoardNode],
        ancestorMatched: Bool,
        rules: LaneRules
    ) -> Lane {
        var collected: [Card] = []
        collectLeaves(nodes, chain: [], search: rules.search, ancestorMatched: ancestorMatched, into: &collected)
        let cards = collected.filter { isShown($0, showDone: rules.showDone, showArchived: rules.showArchived) }
        let known = Set(WorkbenchBoardCard.editableStatuses)
        let columns = rules.statuses.map { status in
            let inColumn = status == otherStatus
                ? cards.filter { !known.contains($0.node.target.status) }
                : cards.filter { $0.node.target.status == status }
            // Uncapped: the per-lane fold replaces the board-wide `doneCap`.
            return column(status, cards: inColumn, showDone: true)
        }
        let counted = leafNodes(nodes).filter { $0.target.status != "dismissed" }
        return Lane(
            root: root,
            title: title,
            columns: columns,
            progress: Lane.Progress(done: counted.filter { $0.target.status == "done" }.count, total: counted.count),
            doneFolded: !rules.showDone,
            doneCount: cards.filter { $0.node.target.status == "done" && !$0.node.archived }.count
        )
    }

    private static func leafNodes(_ nodes: [WorkbenchBoardNode]) -> [WorkbenchBoardNode] {
        nodes.flatMap { $0.children.isEmpty ? [$0] : leafNodes($0.children) }
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

    private static func filterOptions(_ roots: [WorkbenchBoardNode], showArchived: Bool) -> [FilterOption] {
        roots.filter { !$0.children.isEmpty && (showArchived || !$0.archived) }.map {
            FilterOption(id: $0.target.id, title: WorkbenchBoardCard.title($0.target.text))
        }
    }

    private static func applied(_ filterRootID: Int?, among options: [FilterOption]) -> Int? {
        filterRootID.flatMap { id in options.contains { $0.id == id } ? id : nil }
    }

    private static func scope(_ roots: [WorkbenchBoardNode], _ applied: Int?) -> [WorkbenchBoardNode] {
        applied.map { id in roots.filter { $0.target.id == id } } ?? roots
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

/// Kanban's "Lanes" switch: one lane per top-level group, or today's flat
/// columns.
package enum WorkbenchBoardLanesMode: String, CaseIterable {
    case group
    case none
}

/// Per-project Board view state in UserDefaults — view state, not data, so it
/// never touches the database.
package struct WorkbenchBoardPreferences {
    private let defaults: UserDefaults
    private let modeKey: String
    private let filterKey: String
    private let lanesKey: String
    private let foldedLanesKey: String

    package init(workbenchID: Int64, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The `projects.` prefix predates the Workbench rename; persisted, so kept (spec 2026-10-02 A1).
        modeKey = "projects.boardMode.\(workbenchID)"
        filterKey = "projects.boardKanbanFilter.\(workbenchID)"
        lanesKey = "projects.boardLanes.\(workbenchID)"
        foldedLanesKey = "projects.boardFoldedLanes.\(workbenchID)"
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

    /// Defaults to By group; an unknown stored value reads as By group too.
    package var lanesMode: WorkbenchBoardLanesMode {
        get { defaults.string(forKey: lanesKey).flatMap(WorkbenchBoardLanesMode.init(rawValue:)) ?? .group }
        nonmutating set { defaults.set(newValue.rawValue, forKey: lanesKey) }
    }

    /// Folded lanes by `Lane.id` (No group = 0). Stored as given: an id that
    /// is no longer a lane is ignored by the view, not dropped here.
    package var foldedLanes: Set<Int> {
        get { Set(defaults.array(forKey: foldedLanesKey) as? [Int] ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: foldedLanesKey) }
    }
}
