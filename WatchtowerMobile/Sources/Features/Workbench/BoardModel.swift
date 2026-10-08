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
    /// `.ask` for the open-ask count, the only detail that may be orange.
    let role: ToneRole
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
    /// "50%", or "done" for a done target; nil for a leaf with no
    /// progress yet.
    let progressText: String?
    /// A done target shown for context under Open: drawn greyed.
    let isDimmed: Bool

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
        isDimmed = target.status == .done
        if target.status == .done {
            progressText = "done"
        } else if target.childrenCount > 0 || target.progress > 0 {
            progressText = "\(Int((min(1, max(0, target.progress)) * 100).rounded()))%"
        } else {
            progressText = nil
        }

        var details: [BoardDetail] = []
        if target.openAsks > 0 {
            details.append(BoardDetail(text: target.openAsks == 1 ? "1 ask" : "\(target.openAsks) asks", tone: .waitingForYou, role: .ask))
        }
        let sessions = target.sessionIDs.compactMap(snapshot.session)
        if sessions.contains(where: { [.working, .running].contains($0.stateKind) }) {
            details.append(BoardDetail(text: "Session working", tone: .green, role: .info))
        } else if !target.sessionIDs.isEmpty {
            let count = target.sessionIDs.count + (target.sessionIDsMore ?? 0)
            details.append(BoardDetail(text: count == 1 ? "1 session" : "\(count) sessions", tone: .secondary, role: .info))
        }
        if !target.pr.isEmpty {
            details.append(BoardDetail(text: target.pr.allSatisfy(\.isNumber) ? "PR #\(target.pr)" : "PR", tone: .secondary, role: .info))
        }
        self.details = details
    }

    static func status(_ status: WorkbenchTargetStatus) -> (glyph: String, tone: PhoneTone) {
        switch status {
        case .todo: ("circle", .secondary)
        case .inProgress: ("circle.lefthalf.filled", .accent)
        case .inReview: ("circle.dotted.circle", .accent)
        case .blocked: ("exclamationmark.circle.fill", .red)
        case .done: ("checkmark.circle.fill", .secondary)
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
        var uses = [ToneUse(element: "target \(id) status", tone: statusTone, role: .status)]
        uses += details.map { ToneUse(element: "target \(id) \($0.text)", tone: $0.tone, role: $0.role) }
        if priorityLabel != nil {
            uses.append(ToneUse(element: "target \(id) priority", tone: priorityTone, role: .priority))
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
/// filter never mixes archived and live records. Under Open, a shown
/// parent also keeps its done children (greyed), so a group reads whole;
/// the chip counts stay open-only.
struct BoardModel {
    let filter: BoardFilter
    let roots: [BoardNode]
    let visibleIDs: Set<Int64>
    /// New targets the phone asked this workbench's Mac to add, until
    /// hydration delivers them (or the Mac refuses).
    let pendingCreates: [BoardWriteRow]
    private let counts: [BoardFilter: Int]

    init(workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot, filter: BoardFilter, now: Date = Date()) {
        self.filter = filter
        pendingCreates = BoardWriteRow.rows(in: snapshot, now: now) {
            $0.action.kind == .boardTargetCreate
                && (try? BoardTargetCreateParams(wireParams: $0.action.params).workbenchID) == workbenchID
        }
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
        if filter == .open {
            let shownParents = visible
            for target in pool where target.status == .done && target.parentID.map(shownParents.contains) == true {
                visible.insert(target.id)
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
            nodes.flatMap { $0.row.toneUses + walk($0.children) }
        }
        return walk(roots)
    }
}
