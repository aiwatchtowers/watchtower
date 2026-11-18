import Foundation
import WatchtowerKit

/// The board's quick filters (#1781), one row: what needs the owner, what
/// runs, then the status cuts. Archived targets show only under Archive;
/// the other filters never show them (PROJ-15: hidden, not lost).
enum BoardFilter: CaseIterable, Identifiable {
    case waiting, sessions, high, blocked, all, done, archive

    var id: Self { self }

    var title: String {
        switch self {
        case .waiting: "Waiting for me"
        case .sessions: "Sessions running"
        case .high: "High"
        case .blocked: "Blocked"
        case .all: "All"
        case .done: "Done"
        case .archive: "Archive"
        }
    }

    /// What an empty board says under this filter.
    var emptyText: String {
        switch self {
        case .waiting: "Nothing waits for you"
        case .sessions: "No session is running"
        case .high: "No high-priority targets"
        case .blocked: "Nothing blocked"
        case .all: "No open targets"
        case .done: "Nothing done"
        case .archive: "Nothing archived"
        }
    }

    /// The statuses Desktop's switcher counts as open.
    static let openStatuses: Set<WorkbenchTargetStatus> = [.todo, .inProgress, .inReview, .blocked]

    func matches(_ target: WorkbenchTarget, _ signals: BoardSignals) -> Bool {
        let open = Self.openStatuses.contains(target.status)
        switch self {
        case .waiting: return !target.archived && signals.isWaiting(target)
        case .sessions: return !target.archived && signals.isRunning(target)
        case .high: return !target.archived && open && target.priority == .high
        case .blocked: return !target.archived && target.status == .blocked
        case .all: return !target.archived && open
        case .done: return !target.archived && (target.status == .done || target.status == .dismissed)
        case .archive: return target.archived
        }
    }

    /// The board's opening filter: Waiting for me, else Sessions running
    /// when nothing waits, else All.
    static func opening(counts: [Self: Int]) -> Self {
        if (counts[.waiting] ?? 0) > 0 { return .waiting }
        if (counts[.sessions] ?? 0) > 0 { return .sessions }
        return .all
    }
}

/// What waits and what runs per target, from the replica's asks,
/// permission requests and sessions (#1781).
struct BoardSignals {
    /// What waits on one or more targets, by identity, so a group summing
    /// its subtree counts an ask or a prompt shared by two targets once.
    struct Waits: Equatable {
        /// Open asks the phone holds: filed on the target or by its sessions.
        var askIDs: Set<Int64> = []
        /// Asks the Mac counts on a target (`open_asks`) that the replica
        /// does not hold; each belongs to that one target.
        var unseenAsks = 0
        /// Sessions waiting on a permission prompt (one open prompt per
        /// session, the hub closes the older one).
        var approvalSessions: Set<Int64> = []

        var asks: Int { askIDs.count + unseenAsks }
        var approvals: Int { approvalSessions.count }

        mutating func formUnion(_ other: Self) {
            askIDs.formUnion(other.askIDs)
            unseenAsks += other.unseenAsks
            approvalSessions.formUnion(other.approvalSessions)
        }
    }

    private let openAsksByTarget: [Int64: Set<Int64>]
    private let openAsksBySession: [Int64: Set<Int64>]
    private let approvalSessions: Set<Int64>
    private let waitingSessions: Set<Int64>
    private let runningSessions: Set<Int64>

    init(snapshot: WorkbenchReplicaSnapshot, workbenchID: Int64) {
        let asks = snapshot.openAsks(in: workbenchID)
        openAsksByTarget = Dictionary(grouping: asks.filter { $0.targetID != nil }) { $0.targetID ?? 0 }.mapValues { Set($0.map(\.id)) }
        openAsksBySession = Dictionary(grouping: asks.filter { $0.sessionID != nil }) { $0.sessionID ?? 0 }.mapValues { Set($0.map(\.id)) }
        let sessions = snapshot.sessions.filter { $0.workbenchID == workbenchID }
        approvalSessions = Set(snapshot.permissionRequests.map(\.sessionID))
            .union(sessions.filter { $0.stateKind == .needsApproval }.map(\.id))
        waitingSessions = Set(sessions.filter { $0.stateKind == .waitingOnAsk }.map(\.id))
        runningSessions = Set(sessions.filter { [.working, .running].contains($0.stateKind) }.map(\.id))
    }

    func waits(_ target: WorkbenchTarget) -> Waits {
        let filed = openAsksByTarget[target.id] ?? []
        var askIDs = filed
        for session in target.sessionIDs {
            askIDs.formUnion(openAsksBySession[session] ?? [])
        }
        return Waits(
            askIDs: askIDs,
            unseenAsks: max(0, target.openAsks - filed.count),
            approvalSessions: Set(target.sessionIDs.filter(approvalSessions.contains))
        )
    }

    func isWaiting(_ target: WorkbenchTarget) -> Bool {
        let waits = waits(target)
        return waits.asks > 0 || waits.approvals > 0 || target.sessionIDs.contains(where: waitingSessions.contains)
    }

    func runningSessionIDs(_ target: WorkbenchTarget) -> Set<Int64> {
        Set(target.sessionIDs.filter(runningSessions.contains))
    }

    func isRunning(_ target: WorkbenchTarget) -> Bool {
        target.sessionIDs.contains(where: runningSessions.contains)
    }
}

/// One coloured piece of a board row's sub-line; `.ask` for the open-ask
/// count, the only detail that may be orange.
typealias BoardDetail = MetaItem

/// One target row as the target detail's sub-target list shows it: status
/// glyph, title, sub-line (asks, sessions, PR), the priority dot and
/// progress. The board draws the compact card (`BoardNode.card`).
struct BoardRowModel: Equatable, Identifiable {
    let id: Int64
    let title: String
    let statusGlyph: String
    let statusTone: PhoneTone
    /// "In progress", "Done", …: what VoiceOver says for the glyph, and the
    /// row's lane on the board.
    let statusText: String
    let details: [BoardDetail]
    let priority: WorkbenchTargetPriority
    /// Red for high, blue for low; nil (no dot) for medium and unknown.
    let priorityTone: PhoneTone?
    /// "50%", or "done" for a done target; nil for a leaf with no
    /// progress yet.
    let progressText: String?
    /// 0…1 while `progressText` is a percent; nil for "done" and no
    /// progress (no bar).
    let progressValue: Double?
    let progressTone = PhoneTone.green
    /// A done target shown for context: drawn greyed.
    let isDimmed: Bool
    /// The Desktop's board card for this target (mockup 5).
    let card: BoardCardModel

    init(_ target: WorkbenchTarget, snapshot: WorkbenchReplicaSnapshot) {
        id = target.id
        title = target.text
        let status = Self.status(target.status)
        statusGlyph = status.glyph
        statusTone = status.tone
        statusText = Self.label(target)
        priority = target.priority
        priorityTone = PriorityMark.tone(target.priority)
        isDimmed = target.status == .done
        if target.status == .done {
            progressText = "done"
            progressValue = nil
        } else if target.childrenCount > 0 || target.progress > 0 {
            let value = min(1, max(0, target.progress))
            progressText = "\(Int((value * 100).rounded()))%"
            progressValue = value
        } else {
            progressText = nil
            progressValue = nil
        }

        var details: [BoardDetail] = []
        if target.openAsks > 0 {
            details.append(BoardDetail(text: Self.plural(target.openAsks, "ask"), tone: .waitingForYou, role: .ask))
        }
        let sessions = target.sessionIDs.compactMap(snapshot.session)
        if sessions.contains(where: { [.working, .running].contains($0.stateKind) }) {
            details.append(BoardDetail(text: "Session working", tone: .green, role: .info))
        } else if !target.sessionIDs.isEmpty {
            let count = target.sessionIDs.count + (target.sessionIDsMore ?? 0)
            details.append(BoardDetail(text: Self.plural(count, "session"), tone: .secondary, role: .info))
        }
        if let pr = Self.prDetail(target) { details.append(pr) }
        self.details = details
        card = BoardCardModel(
            number: target.id, title: target.text, status: target.status, statusText: statusText, priority: target.priority,
            counter: Self.counter(target, snapshot: snapshot),
            progress: progressValue,
            liveSessions: sessions.filter { [.working, .running].contains($0.stateKind) }.count,
            // The live-session dot is on the card already.
            details: details.filter { $0.text != "Session working" }
        )
    }

    /// The row's label and lane: its board column, else its status label.
    static func label(_ target: WorkbenchTarget) -> String {
        target.column ?? statusLabel(target.status)
    }

    /// A group's counter, the detail's one rule (#1788,
    /// `BoardTargetDetailModel.childCounter`): "0/2 · 1 archived"; nil for a
    /// leaf.
    static func counter(_ target: WorkbenchTarget, snapshot: WorkbenchReplicaSnapshot) -> String? {
        guard target.childrenCount > 0 else { return nil }
        let listed = snapshot.targets.filter { $0.parentID == target.id && $0.archived == target.archived }
        return BoardTargetDetailModel.childCounter(
            done: listed.filter { $0.status == .done }.count, listed: listed.count,
            archived: target.archived ? 0 : target.childrenCount - listed.count
        )
    }

    static func prDetail(_ target: WorkbenchTarget) -> BoardDetail? {
        guard !target.pr.isEmpty else { return nil }
        return BoardDetail(text: target.pr.allSatisfy(\.isNumber) ? "PR #\(target.pr)" : "PR", tone: .secondary, role: .info)
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The Mac's status glyph and tone (`TargetStatusStyle`, design pass
    /// spec §2.3).
    static func status(_ status: WorkbenchTargetStatus) -> (glyph: String, tone: PhoneTone) {
        TargetStatusStyle.of(status)
    }

    static func statusLabel(_ status: WorkbenchTargetStatus) -> String {
        switch status {
        case .todo: "Todo"
        case .inProgress: "In progress"
        case .inReview: "In review"
        case .blocked: "Blocked"
        case .done: "Done"
        case .dismissed: "Dismissed"
        case .snoozed: "Snoozed"
        default: status.rawValue
        }
    }

    /// A meta line is drawn only with something on it.
    var hasMeta: Bool { priorityTone != nil || !details.isEmpty || progressValue != nil }

    /// The dot-and-details line. A row whose meta is only its bar has none,
    /// so no empty line sits above the bar (Phases 1–2 review).
    var hasMetaLine: Bool { priorityTone != nil || !details.isEmpty }

    var toneUses: [ToneUse] {
        var uses = [ToneUse(element: "target \(id) status", tone: statusTone, role: .status)]
        uses += details.map { ToneUse(element: "target \(id) \($0.text)", tone: $0.tone, role: $0.role) }
        if let priorityTone {
            uses.append(ToneUse(element: "target \(id) priority", tone: priorityTone, role: .priority))
        }
        if progressValue != nil {
            uses.append(ToneUse(element: "target \(id) progress", tone: progressTone, role: .progress))
        }
        return uses
    }
}

/// One board tree node: the compact card (#1781) in its lane; a node has a
/// disclosure only when it has visible children.
struct BoardNode: Equatable, Identifiable {
    let id: Int64
    let status: WorkbenchTargetStatus
    /// The lane label of this row on its own: column, else status label.
    let label: String
    let card: BoardCardModel
    /// Done or archived: drawn greyed.
    let isDimmed: Bool
    let children: [Self]
    /// The phone's write on this card (live link R5): a live overlay's caption, or a refused status or priority
    /// write with Dismiss.
    var caption: BoardCardCaption?
    /// False for a new target the phone just asked for: there is no record to open yet.
    var opensDetail = true

    var hasDisclosure: Bool { !children.isEmpty }
}

/// The line under a board card: "Sending…" / "Waiting for your tower" while the phone's own change shows before
/// the replica does, or a refusal (or conflict) of a status or priority write, whose `row` Dismiss removes.
struct BoardCardCaption: Equatable {
    let state: BoardWriteRow.State
    /// The refused write; nil for an overlay's caption.
    let row: BoardWriteRow?
}

/// One lane of the board: the top-level targets sharing a column or status
/// label (mockup 5), in the owner's column order.
struct BoardLane: Identifiable, Equatable {
    enum Kind: Equatable {
        case open, done, archived
    }

    let title: String
    let nodes: [BoardNode]
    let kind: Kind

    var id: String {
        switch kind {
        case .open: "lane:" + title
        case .done: "done:" + title
        case .archived: "archived"
        }
    }

    /// Backlog and Done start folded under All.
    var isFoldedByDefault: Bool {
        kind != .open || title.localizedCaseInsensitiveCompare("Backlog") == .orderedSame
    }

    /// The Mac's Kanban status order (`BoardColumnLayout.openStatusOrder`).
    static func laneRank(_ status: WorkbenchTargetStatus) -> Int {
        switch status {
        case .todo: 0
        case .inProgress: 1
        case .inReview: 2
        case .blocked: 3
        case .done: 4
        default: 5
        }
    }

    /// Roots grouped by their label: status order, then the label's place
    /// in `columns` (the Mac's defined column titles, #1781; a label not
    /// among them after its status's columns), then first seen. An old Mac
    /// sends no columns: status order, then first seen. Done roots share
    /// one lane, placed last.
    static func lanes(_ roots: [BoardNode], columns: [String]?) -> [Self] {
        var order: [String] = []
        var groups: [String: [BoardNode]] = [:]
        for node in roots where node.status != .done {
            if groups[node.label] == nil { order.append(node.label) }
            groups[node.label, default: []].append(node)
        }
        let columns = columns ?? []
        func key(_ title: String, _ seen: Int) -> (Int, Int, Int) {
            let status = groups[title]?.first?.status ?? .todo
            return (laneRank(status), columns.firstIndex(of: title) ?? columns.count, seen)
        }
        let sorted = order.enumerated().sorted { key($0.element, $0.offset) < key($1.element, $1.offset) }.map(\.element)
        var lanes = sorted.map { Self(title: $0, nodes: groups[$0] ?? [], kind: .open) }
        let done = roots.filter { $0.status == .done }
        if !done.isEmpty { lanes.append(Self(title: "Done", nodes: done, kind: .done)) }
        return lanes
    }
}

/// The board under one quick filter, or a search (#1781): the matching
/// targets plus, for context, their ancestors from the same pool (archived
/// or not), so a tree never mixes archived and live records, laid out in
/// lanes. A search covers the whole board: live matches in their lanes,
/// archived ones in one Archived lane at the end.
struct BoardModel {
    static let searchPrompt = "Search title, #number, branch"

    /// The filter shown: the owner's choice, else the opening filter.
    let filter: BoardFilter
    /// The trimmed search; empty when not searching.
    let query: String
    let lanes: [BoardLane]
    let visibleIDs: Set<Int64>
    /// The live roots (every lane but Archived), for the tree's tests.
    let roots: [BoardNode]
    /// Targets matching the search; 0 when not searching.
    let matchCount: Int
    /// New targets the phone asked this workbench's Mac to add, until
    /// hydration delivers them (or the Mac refuses); one shown as a card in
    /// its lane (a live top-level create overlay) is not listed again.
    let pendingCreates: [BoardWriteRow]
    /// The phone's replies on this workbench whose thread is not in the
    /// replica at all, so no target can show them.
    let unplacedReplies: [BoardWriteRow]
    private let counts: [BoardFilter: Int]

    init(
        workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot, filter: BoardFilter? = nil, query: String = "", now: Date = Date()
    ) {
        unplacedReplies = BoardWriteRow.rows(in: snapshot, now: now) {
            $0.action.kind == .boardCommentReply
                && (try? BoardCommentReplyParams(wireParams: $0.action.params).workbenchID) == workbenchID
                && BoardTargetDetailModel.replyTarget(of: $0, in: snapshot) == nil
        }
        let board = snapshot.targets.filter { $0.workbenchID == workbenchID }
        let signals = BoardSignals(snapshot: snapshot, workbenchID: workbenchID)
        var counts: [BoardFilter: Int] = [:]
        for chip in BoardFilter.allCases where chip != .archive {
            counts[chip] = board.filter { chip.matches($0, signals) }.count
        }
        self.counts = counts
        let filter = filter ?? BoardFilter.opening(counts: counts)
        self.filter = filter
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        let columns = snapshot.workbench(workbenchID)?.boardColumns

        let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
        let tree = BoardTree(snapshot: snapshot, signals: signals, captions: Self.captions(board, snapshot: snapshot, now: now))
        let created = query.isEmpty && filter != .archive ? Self.createdCards(workbenchID: workbenchID, snapshot: snapshot) : []
        let carded = Set(created.map(\.actionID))
        pendingCreates = BoardWriteRow.rows(in: snapshot, now: now) {
            $0.action.kind == .boardTargetCreate
                && (try? BoardTargetCreateParams(wireParams: $0.action.params).workbenchID) == workbenchID
                && !carded.contains($0.id)
        }
        if query.isEmpty {
            let pool = board.filter { $0.archived == (filter == .archive) }
            let shown = tree.build(pool: pool) { filter.matches($0, signals) }
            roots = shown.roots
            visibleIDs = shown.visible
            matchCount = 0
            let newCards = created.enumerated().map { Self.createdNode($1, id: -Int64($0 + 1), macOnline: online) }
            lanes = BoardLane.lanes(shown.roots + newCards, columns: columns)
        } else {
            let match = { (target: WorkbenchTarget) in Self.matches(target, query: query) }
            let live = tree.build(pool: board.filter { !$0.archived }, match: match)
            let archived = tree.build(pool: board.filter(\.archived), match: match)
            roots = live.roots
            visibleIDs = live.visible.union(archived.visible)
            matchCount = board.filter(match).count
            var lanes = BoardLane.lanes(live.roots, columns: columns)
            if !archived.roots.isEmpty {
                lanes.append(BoardLane(title: "Archived", nodes: archived.roots, kind: .archived))
            }
            self.lanes = lanes
        }
    }

    var isSearching: Bool { !query.isEmpty }

    /// Each target's card line: its newest live status or priority overlay's caption, else its newest refused
    /// status or priority write.
    private static func captions(
        _ board: [WorkbenchTarget], snapshot: WorkbenchReplicaSnapshot, now: Date
    ) -> [Int64: BoardCardCaption] {
        let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
        var captions: [Int64: BoardCardCaption] = [:]
        let refused = BoardWriteRow.rows(in: snapshot, now: now) {
            $0.state == .failed && [.boardTargetStatus, .boardTargetPriority].contains($0.action.kind)
        }
        for row in refused {
            guard let id = row.pending.action.entityID.flatMap(Int64.init) else { continue }
            captions[id] = BoardCardCaption(state: row.state, row: row)
        }
        for target in board {
            if let overlay = snapshot.fieldOverlay(on: target.id) {
                captions[target.id] = BoardCardCaption(state: overlay.caption(macOnline: online), row: nil)
            }
        }
        return captions
    }

    /// The live top-level create overlays of this workbench: each is a card in its status's lane (a sub-target's
    /// stays a pending row: its parent's tree is the Mac's).
    private static func createdCards(workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot) -> [PendingOverlay] {
        snapshot.overlays.filter {
            if case let .create(workbench, parent, _, _) = $0.expected { return workbench == workbenchID && parent == nil }
            return false
        }
    }

    /// A new target's card before its record exists: Todo, no number, nothing to open.
    private static func createdNode(_ overlay: PendingOverlay, id: Int64, macOnline: Bool) -> BoardNode {
        guard case let .create(_, _, title, priority) = overlay.expected else { preconditionFailure("a create overlay") }
        let label = BoardRowModel.statusLabel(.todo)
        return BoardNode(
            id: id, status: .todo, label: label,
            card: BoardCardModel(
                number: nil, title: title, status: .todo, statusText: label, priority: priority, compact: true, statusChip: false
            ),
            isDimmed: false, children: [],
            caption: BoardCardCaption(state: overlay.caption(macOnline: macOnline), row: nil), opensDetail: false
        )
    }

    /// Groups and lanes fold (and remember it) only under All; a narrower
    /// filter or a search shows every match open, so no fold hides one.
    var folds: Bool { !isSearching && filter == .all }

    /// "3 matches" over a search; nil when nothing matches (the empty line
    /// says it).
    var searchCaption: String? {
        guard matchCount > 0 else { return nil }
        return matchCount == 1 ? "1 match" : "\(matchCount) matches"
    }

    /// What an empty board says; nil with any lane.
    var emptyText: String? {
        guard lanes.isEmpty else { return nil }
        return isSearching ? "No target matches \u{201C}\(query)\u{201D}" : filter.emptyText
    }

    /// Title (contains), branch (contains) or number: "#42" and "42" match
    /// ids starting 42; "#42" matches only ids. Case and diacritics ignored.
    static func matches(_ target: WorkbenchTarget, query: String) -> Bool {
        let hashed = query.hasPrefix("#")
        let digits = hashed ? String(query.dropFirst()) : query
        if !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), String(target.id).hasPrefix(digits) {
            return true
        }
        if hashed { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return target.text.range(of: query, options: options) != nil
            || (!target.branch.isEmpty && target.branch.range(of: query, options: options) != nil)
    }

    /// Sibling order of the board, as the Mac shows it: priority high,
    /// medium, then anything else; then status in_progress, in_review,
    /// blocked, todo, done, then anything else; then id. A twin of Core's
    /// `WorkbenchBoardOrder` and Go's `boardSiblingOrder`
    /// (`internal/db/workbench_board.go`); change all three together.
    static func boardOrder(_ lhs: WorkbenchTarget, _ rhs: WorkbenchTarget) -> Bool {
        (priorityRank(lhs.priority), statusRank(lhs.status), lhs.id)
            < (priorityRank(rhs.priority), statusRank(rhs.status), rhs.id)
    }

    static func priorityRank(_ priority: WorkbenchTargetPriority) -> Int {
        switch priority {
        case .high: 0
        case .medium: 1
        default: 2
        }
    }

    static func statusRank(_ status: WorkbenchTargetStatus) -> Int {
        switch status {
        case .inProgress: 0
        case .inReview: 1
        case .blocked: 2
        case .todo: 3
        case .done: 4
        default: 5
        }
    }

    /// The chip's count; nil for Archive, which carries none.
    func count(_ filter: BoardFilter) -> Int? {
        counts[filter]
    }

    var toneUses: [ToneUse] {
        func walk(_ nodes: [BoardNode]) -> [ToneUse] {
            nodes.flatMap { $0.card.toneUses + walk($0.children) }
        }
        return lanes.flatMap { walk($0.nodes) }
    }
}

/// Builds the board tree from one pool (#1781): the matches and their
/// ancestors, in board order, each with its compact card.
private struct BoardTree {
    let snapshot: WorkbenchReplicaSnapshot
    let signals: BoardSignals
    let captions: [Int64: BoardCardCaption]

    func build(pool: [WorkbenchTarget], match: (WorkbenchTarget) -> Bool) -> (roots: [BoardNode], visible: Set<Int64>) {
        let byID = Dictionary(pool.map { ($0.id, $0) }) { first, _ in first }
        var visible = Set<Int64>()
        for target in pool where match(target) {
            var cursor: WorkbenchTarget? = target
            while let current = cursor, visible.insert(current.id).inserted {
                cursor = current.parentID.flatMap { byID[$0] }
            }
        }
        let shown = pool.filter { visible.contains($0.id) }.sorted(by: BoardModel.boardOrder)
        let childrenByParent = Dictionary(grouping: shown.filter { $0.parentID.map(visible.contains) == true }) { $0.parentID ?? 0 }
        let allChildren = Dictionary(grouping: pool.filter { $0.parentID != nil }) { $0.parentID ?? 0 }
        func node(_ target: WorkbenchTarget, lane: String) -> BoardNode {
            BoardNode(
                id: target.id, status: target.status, label: BoardRowModel.label(target),
                card: card(target, lane: lane, subtree: subtree(target, allChildren)),
                isDimmed: target.archived || target.status == .done,
                children: (childrenByParent[target.id] ?? []).map { node($0, lane: lane) },
                caption: captions[target.id]
            )
        }
        let roots = shown.filter { $0.parentID.map(visible.contains) != true }.map { node($0, lane: BoardRowModel.label($0)) }
        return (roots, visible)
    }

    /// The target and every descendant in the pool.
    private func subtree(_ target: WorkbenchTarget, _ children: [Int64: [WorkbenchTarget]]) -> [WorkbenchTarget] {
        [target] + (children[target.id] ?? []).flatMap { subtree($0, children) }
    }

    /// The compact card (#1781): the status chip only when the row's label
    /// is not its lane's, High as a dot, progress on groups only; a group
    /// sums its subtree's asks, approvals and running sessions.
    private func card(_ target: WorkbenchTarget, lane: String, subtree: [WorkbenchTarget]) -> BoardCardModel {
        let isGroup = target.childrenCount > 0
        let scope = isGroup ? subtree : [target]
        let waits = scope.reduce(into: BoardSignals.Waits()) { $0.formUnion(signals.waits($1)) }
        let asks = waits.asks
        let approvals = waits.approvals
        let running = scope.reduce(into: Set<Int64>()) { $0.formUnion(signals.runningSessionIDs($1)) }
        var details: [BoardDetail] = []
        if asks > 0 {
            details.append(BoardDetail(text: BoardRowModel.plural(asks, "ask"), tone: .waitingForYou, role: .ask))
        }
        if approvals > 0 {
            details.append(BoardDetail(text: BoardRowModel.plural(approvals, "approval"), tone: .waitingForYou, role: .ask))
        }
        if running.isEmpty, !isGroup, !target.sessionIDs.isEmpty {
            let count = target.sessionIDs.count + (target.sessionIDsMore ?? 0)
            details.append(BoardDetail(text: BoardRowModel.plural(count, "session"), tone: .secondary, role: .info))
        }
        if let pr = BoardRowModel.prDetail(target) { details.append(pr) }
        let label = BoardRowModel.label(target)
        return BoardCardModel(
            number: target.id, title: target.text, status: target.status, statusText: label, priority: target.priority,
            counter: BoardRowModel.counter(target, snapshot: snapshot),
            progress: isGroup && target.status != .done ? target.progress : nil,
            liveSessions: running.count,
            details: details,
            compact: true,
            statusChip: label != lane
        )
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
