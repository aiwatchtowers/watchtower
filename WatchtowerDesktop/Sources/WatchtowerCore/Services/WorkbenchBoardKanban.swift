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
        /// The parent chain below the board's scope (in a lane, below the
        /// lane root), " › "-joined; empty for a card right under it.
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

    /// One lane of the "Lanes: By group" layout (spec 2026-10-06 Part 2): a
    /// group's leaves, the top-level leaves under No group, or inside a
    /// scope the scope's own leaf children under "Tasks", in the board's
    /// columns. The Done column holds every done card, never
    /// capped; folding it is the view's (`doneFolded`, `cards(_:unfolded:)`).
    package struct Lane: Identifiable {
        /// The lane's `WorkbenchGroupSummary` (the panel's and the path
        /// bar's rule): done leaves over the leaves that still count,
        /// archived ones only with the Archive toggle on, whatever the other
        /// filters and the search. `total` may be 0.
        package struct Progress: Equatable {
            package let done: Int
            package let total: Int
        }

        /// The lane's group; nil for the No group lane; the scope itself
        /// for a scope's "Tasks" lane.
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

        /// The root's id; the No group lane folds under id 0. A scope's
        /// "Tasks" lane shares the scope's id: one fold per group, so a
        /// group folded as a lane opens with its Tasks folded too.
        package var id: Int { root?.target.id ?? 0 }

        /// What `column` shows: with the Done fold closed, its live done
        /// cards are left out.
        package func cards(_ column: Column, unfolded: Bool) -> [Card] {
            guard column.status == "done", doneFolded, !unfolded else { return column.cards }
            return column.cards.filter(\.node.archived)
        }

        /// Whether the lane shows a card with its Done fold closed: a kept
        /// lane without one says "No open tasks" (spec 2026-10-06 Part 2).
        package var hasVisibleCards: Bool {
            columns.contains { !cards($0, unfolded: false).isEmpty }
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
    /// last — inside a scope, "Tasks" first and no No group. A lane with
    /// nothing to show is left out, except one whose root is open while the
    /// search is empty (the view says "No open tasks").
    package let lanes: [Lane]
    /// Per column status, the cards in that column over `lanes`: the totals
    /// row above the lanes.
    package let totals: [String: Int]
    /// The scope actually applied (`WorkbenchBoardScope`): nil (the board
    /// root) when the requested one is stale.
    package let scopeID: Int?
    /// Archived leaves under the scope "Archive" on would apply, whatever
    /// the toggles and the search: the cards "Archive" adds, Kanban's
    /// "Archive (K)".
    package let archivedCardCount: Int

    /// A non-empty `query` (`WorkbenchBoardSearch`) keeps the leaves it
    /// matches and the leaves under a parent it matches, and shows the done,
    /// dismissed and archived ones as if "Show done" and "Archive" were on.
    /// With "Archive" on and "Show done" off, the Dismissed column holds only
    /// archived cards.
    ///
    /// A `scopeID` (spec 2026-10-06 Part 4, `WorkbenchBoardScope`) keeps the
    /// scope's leaves only, breadcrumbs starting below it; a search inside
    /// it keeps what the same search on the whole board keeps there.
    package init(
        _ roots: [WorkbenchBoardNode],
        scopeID: Int?,
        showDone: Bool,
        showArchived: Bool = false,
        query: String = ""
    ) {
        let search = WorkbenchBoardSearch(query)
        let archiveToggle = showArchived
        let showDone = showDone || search != nil
        let showArchived = showArchived || search != nil
        let scope = WorkbenchBoardScope.resolve(scopeID, in: roots, showArchived: showArchived)
        let nodes = scope.node?.children ?? roots
        let pathMatched = WorkbenchBoardScope.pathMatches(scope.path, search)

        var collected: [Card] = []
        Self.collectLeaves(nodes, chain: [], search: search, ancestorMatched: pathMatched, into: &collected)
        let leaves = collected.filter { Self.isShown($0, showDone: showDone, showArchived: showArchived) }

        var statuses = ["todo", "in_progress", "in_review", "blocked", "done"]
        if showDone || showArchived { statuses.append("dismissed") }
        if leaves.contains(where: { !Self.knownStatuses.contains($0.node.target.status) }) {
            statuses.append(Self.otherStatus)
        }
        let columns = statuses.map { status in
            Self.column(status, cards: Self.cards(leaves, inColumn: status), showDone: showDone)
        }

        self.columns = columns
        let lanes = Self.lanes(scope.node, roots: roots, pathMatched: pathMatched, LaneRules(
            statuses: statuses, search: search, showDone: showDone, showArchived: showArchived,
            archiveToggle: archiveToggle
        ))
        self.lanes = lanes
        self.totals = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column.status, lanes.reduce(0) { sum, lane in
                sum + (lane.columns.first { $0.status == column.status }?.cards.count ?? 0)
            })
        })
        self.scopeID = scope.node?.target.id
        // Counted over what "Archive" on shows: a remembered scope under an
        // archived target applies only then.
        let archiveScope = WorkbenchBoardScope.resolve(scopeID, in: roots, showArchived: true).node
        self.archivedCardCount = Self.archivedLeafCount(archiveScope?.children ?? roots)
    }

    /// Whether a double-click on `lane`'s header enters its group: not the
    /// No group lane, not the scope's own "Tasks" lane (it would re-enter
    /// the scope).
    package static func entersGroup(_ lane: Lane, scopeID: Int?) -> Bool {
        lane.root != nil && lane.id != scopeID
    }

    /// Whether `lane`'s header offers Work on It (#472): only a group's lane
    /// — the scope's own "Tasks" lane is worked from the path bar's group.
    package static func showsWorkOn(_ lane: Lane, scopeID: Int?) -> Bool {
        guard entersGroup(lane, scopeID: scopeID), let root = lane.root else { return false }
        return !root.children.isEmpty
    }

    /// Whether `id` is a card shown on this board. A drop accepts only these:
    /// the drop payload is plain text, so a number dragged in from elsewhere
    /// (or a parent's id) must never move a target.
    package func showsCard(_ id: Int) -> Bool {
        columns.contains { $0.cards.contains { $0.id == id } }
    }

    private static let knownStatuses = Set(WorkbenchBoardCard.editableStatuses)

    /// The cards of `cards` that belong in the `status` column: the Other
    /// column takes every status this build does not know.
    private static func cards(_ cards: [Card], inColumn status: String) -> [Card] {
        status == otherStatus
            ? cards.filter { !knownStatuses.contains($0.node.target.status) }
            : cards.filter { $0.node.target.status == status }
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
        /// The Archive toggle as the owner set it (a search does not turn
        /// it on): the lanes' progress rule.
        let archiveToggle: Bool
    }

    /// Lays out the board root's `roots`, or the `scope`'s children: each
    /// one with children is a lane; the leaves among them share the No group
    /// lane (last) at the root, the scope's "Tasks" lane (first) inside it.
    /// `pathMatched`: the search matches the scope or one of its ancestors.
    private static func lanes(
        _ scope: WorkbenchBoardNode?,
        roots: [WorkbenchBoardNode],
        pathMatched: Bool,
        _ rules: LaneRules
    ) -> [Lane] {
        let nodes = scope?.children ?? roots
        let groups = Dictionary(uniqueKeysWithValues: nodes.filter { !$0.children.isEmpty }.map { ($0.target.id, $0) })
        let ordered = WorkbenchBoardOrder.sorted(groups.values.map(\.target)).compactMap { groups[$0.id] }
        var lanes = ordered.map { root in
            lane(root: root, title: WorkbenchBoardCard.title(root.target.text), nodes: root.children,
                 ancestorMatched: pathMatched || (rules.search?.matches(root.target) ?? false), rules: rules)
        }
        let loose = nodes.filter(\.children.isEmpty)
        if !loose.isEmpty {
            if let scope {
                lanes.insert(lane(root: scope, title: "Tasks", nodes: loose, ancestorMatched: pathMatched, rules: rules), at: 0)
            } else {
                lanes.append(lane(root: nil, title: "No group", nodes: loose, ancestorMatched: false, rules: rules))
            }
        }
        return lanes.filter { lane in
            let shows = lane.hasVisibleCards
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
        // Uncapped: the per-lane fold replaces the board-wide `doneCap`.
        let columns = rules.statuses.map { column($0, cards: Self.cards(cards, inColumn: $0), showDone: true) }
        let summary = WorkbenchGroupSummary(over: nodes, showArchived: rules.archiveToggle)
        return Lane(
            root: root,
            title: title,
            columns: columns,
            progress: Lane.Progress(done: summary.done, total: summary.total),
            doneFolded: !rules.showDone,
            doneCount: cards.filter { $0.node.target.status == "done" && !$0.node.archived }.count
        )
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
    private let scopeKey: String
    private let lanesKey: String
    private let foldedLanesKey: String

    package init(workbenchID: Int64, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The `projects.` prefix predates the Workbench rename; persisted, so kept (spec 2026-10-02 A1).
        modeKey = "projects.boardMode.\(workbenchID)"
        scopeKey = "projects.boardKanbanFilter.\(workbenchID)"
        lanesKey = "projects.boardLanes.\(workbenchID)"
        foldedLanesKey = "projects.boardFoldedLanes.\(workbenchID)"
    }

    /// Defaults to List; an unknown stored value reads as List too.
    package var mode: WorkbenchBoardMode {
        get { defaults.string(forKey: modeKey).flatMap(WorkbenchBoardMode.init(rawValue:)) ?? .list }
        nonmutating set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    /// The board scope's target id (any depth); nil = the board root. On the
    /// pre-scope filter's key, so a remembered top-level filter carries
    /// over. A stale id is resolved by `WorkbenchBoardScope`, not here.
    package var boardScopeID: Int? {
        get { defaults.object(forKey: scopeKey) == nil ? nil : defaults.integer(forKey: scopeKey) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: scopeKey) } else { defaults.removeObject(forKey: scopeKey) }
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
