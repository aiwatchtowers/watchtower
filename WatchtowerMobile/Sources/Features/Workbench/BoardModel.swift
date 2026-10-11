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

/// One coloured piece of a board row's sub-line; `.ask` for the open-ask
/// count, the only detail that may be orange.
typealias BoardDetail = MetaItem

/// One board row: status glyph, title, sub-line (asks, sessions, PR), the
/// priority dot and progress.
struct BoardRowModel: Equatable, Identifiable {
    let id: Int64
    let title: String
    let statusGlyph: String
    let statusTone: PhoneTone
    /// "In progress", "Done", …: what VoiceOver says for the glyph.
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
    /// A done target shown for context under Open: drawn greyed.
    let isDimmed: Bool

    init(_ target: WorkbenchTarget, snapshot: WorkbenchReplicaSnapshot) {
        id = target.id
        title = target.text
        let status = Self.status(target.status)
        statusGlyph = status.glyph
        statusTone = status.tone
        statusText = Self.statusLabel(target.status)
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
    /// The phone's replies on this workbench whose thread is not in the
    /// replica at all, so no target can show them.
    let unplacedReplies: [BoardWriteRow]
    private let counts: [BoardFilter: Int]

    init(workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot, filter: BoardFilter, now: Date = Date()) {
        self.filter = filter
        pendingCreates = BoardWriteRow.rows(in: snapshot, now: now) {
            $0.action.kind == .boardTargetCreate
                && (try? BoardTargetCreateParams(wireParams: $0.action.params).workbenchID) == workbenchID
        }
        unplacedReplies = BoardWriteRow.rows(in: snapshot, now: now) {
            $0.action.kind == .boardCommentReply
                && (try? BoardCommentReplyParams(wireParams: $0.action.params).workbenchID) == workbenchID
                && BoardTargetDetailModel.replyTarget(of: $0, in: snapshot) == nil
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
