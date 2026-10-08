import Foundation
import WatchtowerKit

/// The board's filter chips (spec §13 B2). Archived targets show only under
/// Archive; the other filters never show them (PROJ-15: hidden, not lost).
enum BoardFilter: CaseIterable, Identifiable {
    case open, inProgress, blocked, archive

    var id: Self { self }

    var title: String {
        switch self {
        case .open: "Open"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .archive: "Archive"
        }
    }

    /// The statuses Desktop's switcher counts as open.
    static let openStatuses: Set<WorkbenchTargetStatus> = [.todo, .inProgress, .inReview, .blocked]

    func matches(_ target: WorkbenchTarget) -> Bool {
        switch self {
        case .open: !target.archived && Self.openStatuses.contains(target.status)
        case .inProgress: !target.archived && target.status == .inProgress
        case .blocked: !target.archived && target.status == .blocked
        case .archive: target.archived
        }
    }
}

/// One coloured piece of a board row's sub-line.
struct BoardDetail: Equatable {
    let text: String
    let tone: PhoneTone
    /// The open-ask count: an ask element, so it may be orange.
    var isAsk = false
}

/// One board row: status glyph, title, sub-line (asks, sessions, PR),
/// priority and progress.
struct BoardRowModel: Equatable, Identifiable {
    let id: Int64
    let title: String
    let statusGlyph: String
    let statusTone: PhoneTone
    let details: [BoardDetail]
    /// "HIGH" or "LOW"; nil for medium, the default.
    let priorityLabel: String?
    let priorityTone: PhoneTone
    /// "50%"; nil for a leaf with no progress yet.
    let progressText: String?

    init(_ target: WorkbenchTarget, snapshot: WorkbenchReplicaSnapshot) {
        id = target.id
        title = target.text
        let status = Self.status(target.status)
        statusGlyph = status.glyph
        statusTone = status.tone
        priorityLabel = switch target.priority {
        case .high: "HIGH"
        case .low: "LOW"
        default: nil
        }
        priorityTone = target.priority == .high ? .red : .secondary
        progressText = target.childrenCount > 0 || target.progress > 0
            ? "\(Int((min(1, max(0, target.progress)) * 100).rounded()))%"
            : nil

        var details: [BoardDetail] = []
        if target.openAsks > 0 {
            details.append(BoardDetail(text: target.openAsks == 1 ? "1 ask" : "\(target.openAsks) asks", tone: .orange, isAsk: true))
        }
        let sessions = target.sessionIDs.compactMap(snapshot.session)
        if sessions.contains(where: { [.working, .running].contains($0.stateKind) }) {
            details.append(BoardDetail(text: "Session working", tone: .green))
        } else if !target.sessionIDs.isEmpty {
            let count = target.sessionIDs.count + (target.sessionIDsMore ?? 0)
            details.append(BoardDetail(text: count == 1 ? "1 session" : "\(count) sessions", tone: .secondary))
        }
        if !target.pr.isEmpty {
            details.append(BoardDetail(text: target.pr.allSatisfy(\.isNumber) ? "PR #\(target.pr)" : "PR", tone: .secondary))
        }
        self.details = details
    }

    static func status(_ status: WorkbenchTargetStatus) -> (glyph: String, tone: PhoneTone) {
        switch status {
        case .todo: ("circle", .secondary)
        case .inProgress: ("circle.lefthalf.filled", .accent)
        case .inReview: ("circle.dotted.circle", .accent)
        case .blocked: ("exclamationmark.circle.fill", .red)
        case .done: ("checkmark.circle.fill", .green)
        case .dismissed: ("xmark.circle", .secondary)
        case .snoozed: ("moon.circle", .secondary)
        default: ("circle", .secondary)
        }
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

    var toneUses: [ToneUse] {
        var uses = [ToneUse(element: "target \(id) status", tone: statusTone, isWaitingOrAsk: false)]
        uses += details.map { ToneUse(element: "target \(id) \($0.text)", tone: $0.tone, isWaitingOrAsk: $0.isAsk) }
        if priorityLabel != nil {
            uses.append(ToneUse(element: "target \(id) priority", tone: priorityTone, isWaitingOrAsk: false))
        }
        return uses
    }
}

/// One tree node; a node has a disclosure only when it has visible children.
struct BoardNode: Equatable, Identifiable {
    let row: BoardRowModel
    let children: [Self]

    var id: Int64 { row.id }
    var hasDisclosure: Bool { !children.isEmpty }
}

/// The board tree under one filter: the matching targets plus, for
/// context, their ancestors from the same pool (archived or not), so a
/// filter never mixes archived and live records.
struct BoardModel {
    let filter: BoardFilter
    let roots: [BoardNode]
    let visibleIDs: Set<Int64>
    private let counts: [BoardFilter: Int]

    init(workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot, filter: BoardFilter) {
        self.filter = filter
        let board = snapshot.targets.filter { $0.workbenchID == workbenchID }
        let pool = board.filter { $0.archived == (filter == .archive) }
        let byID = Dictionary(pool.map { ($0.id, $0) }) { first, _ in first }

        var visible = Set<Int64>()
        for target in pool where filter.matches(target) {
            var cursor: WorkbenchTarget? = target
            while let current = cursor, visible.insert(current.id).inserted {
                cursor = current.parentID.flatMap { byID[$0] }
            }
        }
        visibleIDs = visible

        let shown = pool.filter { visible.contains($0.id) }.sorted(by: Self.boardOrder)
        let childrenByParent = Dictionary(grouping: shown.filter { $0.parentID.map(visible.contains) == true }) { $0.parentID ?? 0 }
        func node(_ target: WorkbenchTarget) -> BoardNode {
            BoardNode(row: BoardRowModel(target, snapshot: snapshot), children: (childrenByParent[target.id] ?? []).map(node))
        }
        roots = shown.filter { $0.parentID.map(visible.contains) != true }.map(node)

        var counts: [BoardFilter: Int] = [:]
        for chip in BoardFilter.allCases where chip != .archive {
            counts[chip] = board.filter(chip.matches).count
        }
        self.counts = counts
    }

    /// Oldest first, then by id: the order targets were put on the board.
    static func boardOrder(_ lhs: WorkbenchTarget, _ rhs: WorkbenchTarget) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id < rhs.id
    }

    /// The chip's count; nil for Archive, which carries none.
    func count(_ filter: BoardFilter) -> Int? {
        counts[filter]
    }

    var toneUses: [ToneUse] {
        func walk(_ nodes: [BoardNode]) -> [ToneUse] {
            nodes.flatMap { $0.row.toneUses + walk($0.children) }
        }
        return walk(roots)
    }
}

/// A board target's read-only detail: status, priority, progress, intent,
/// branch and PR, sub-targets, linked sessions, open asks and comments.
struct BoardTargetDetailModel {
    struct CommentRow: Equatable, Identifiable {
        let id: Int64
        let author: String
        let body: String
        let age: String
        let isReply: Bool
        let isResolved: Bool
    }

    let id: Int64
    let title: String
    let statusLabel: String
    let row: BoardRowModel
    let intent: String
    let branch: String
    let pr: String
    let children: [BoardRowModel]
    let sessions: [SessionRowModel]
    let asks: [WaitingCardModel]
    let comments: [CommentRow]

    init?(targetID: Int64, snapshot: WorkbenchReplicaSnapshot, now: Date) {
        guard let target = snapshot.targets.first(where: { $0.id == targetID }) else { return nil }
        id = target.id
        title = target.text
        statusLabel = BoardRowModel.statusLabel(target.status)
        row = BoardRowModel(target, snapshot: snapshot)
        intent = target.intent
        branch = target.branch
        pr = target.pr
        // A live target's archived children stay under Archive.
        children = snapshot.targets
            .filter { $0.parentID == target.id && $0.archived == target.archived }
            .sorted(by: BoardModel.boardOrder)
            .map { BoardRowModel($0, snapshot: snapshot) }
        sessions = target.sessionIDs.compactMap(snapshot.session).map { SessionRowModel($0, now: now) }
        asks = snapshot.openAsks(in: target.workbenchID)
            .filter { $0.targetID == target.id }
            .map { WaitingCardModel($0, snapshot: snapshot, now: now) }
        comments = Self.thread(snapshot.comments.filter { $0.targetID == target.id }, now: now)
    }

    /// Roots oldest first, each followed by its whole thread oldest first.
    private static func thread(_ comments: [WorkbenchComment], now: Date) -> [CommentRow] {
        let ordered = comments.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
        let byID = Dictionary(ordered.map { ($0.id, $0) }) { first, _ in first }
        // A comment whose parent is not shown is a root.
        func rootID(of comment: WorkbenchComment) -> Int64 {
            var current = comment
            var seen: Set<Int64> = [current.id]
            while let parent = current.parentID.flatMap({ byID[$0] }), seen.insert(parent.id).inserted {
                current = parent
            }
            return current.id
        }
        let threads = Dictionary(grouping: ordered, by: rootID)
        let roots = ordered.filter { rootID(of: $0) == $0.id }
        return roots.flatMap { root in
            (threads[root.id] ?? [root]).map { comment in
                CommentRow(
                    id: comment.id,
                    author: comment.author == .owner ? "You" : (comment.agentLabel.isEmpty ? "Agent" : comment.agentLabel),
                    body: comment.body,
                    age: CompactAge.string(from: comment.createdAt, now: now),
                    isReply: comment.id != root.id,
                    isResolved: comment.status == .resolved
                )
            }
        }
    }

    var toneUses: [ToneUse] {
        row.toneUses + children.flatMap(\.toneUses) + sessions.flatMap(\.toneUses) + asks.map(\.toneUse)
    }
}
