import Foundation
import WatchtowerKit
import WatchtowerSync

/// A board target's detail: breadcrumb, status and priority pickers,
/// progress, intent, branch and PR, sub-targets, linked sessions, open asks,
/// the comment threads and the phone's own writes not yet applied. An
/// archived target is read-only on the phone (a POC choice: Archive stays a
/// read view, though the hub would accept the writes).
struct BoardTargetDetailModel {
    struct CommentRow: Equatable, Identifiable {
        let id: Int64
        let author: String
        let body: String
        let age: String
        let isReply: Bool
        let isResolved: Bool
        /// The thread's first comment; a reply goes under it.
        let rootID: Int64
        /// A root of a target the phone may write to (resolved roots too:
        /// the Mac reopens them).
        let canReply: Bool
    }

    /// The thread as drawn: the posted comments with the phone's pending or
    /// failed comments and replies in place.
    enum ThreadItem: Equatable, Identifiable {
        case comment(CommentRow)
        case write(BoardWriteRow, isReply: Bool)

        var id: String {
            switch self {
            case let .comment(row): "comment-\(row.id)"
            case let .write(row, _): "action-\(row.id)"
            }
        }

        var isReply: Bool {
            switch self {
            case let .comment(row): row.isReply
            case let .write(_, isReply): isReply
            }
        }
    }

    struct Crumb: Equatable, Identifiable {
        let id: Int64
        let title: String
    }

    let id: Int64
    let target: WorkbenchTarget
    let title: String
    let statusLabel: String
    let row: BoardRowModel
    /// Ancestors, root first, as far as the replica has them.
    let breadcrumb: [Crumb]
    let isReadOnly: Bool
    let status: BoardFieldPicker<WorkbenchTargetStatus>
    let priority: BoardFieldPicker<WorkbenchTargetPriority>
    /// The phone's status and priority writes on this target.
    let writes: [BoardWriteRow]
    let intent: String
    let branch: String
    let pr: String
    let children: [BoardRowModel]
    /// "Sub-targets · 1 / 3".
    let childrenHeader: String
    let sessions: [SessionRowModel]
    let asks: [WaitingCardModel]
    let comments: [CommentRow]
    let thread: [ThreadItem]

    init?(targetID: Int64, snapshot: WorkbenchReplicaSnapshot, now: Date) {
        guard let target = snapshot.targets.first(where: { $0.id == targetID }) else { return nil }
        id = target.id
        self.target = target
        title = target.text
        statusLabel = BoardRowModel.statusLabel(target.status)
        row = BoardRowModel(target, snapshot: snapshot)
        breadcrumb = Self.breadcrumb(of: target, in: snapshot)
        isReadOnly = target.archived
        intent = target.intent
        branch = target.branch
        pr = target.pr

        let entity = SliceKind.workbenchTarget.recordName(id: String(target.id))
        let fieldWrites = BoardWriteRow.rows(in: snapshot, now: now) {
            $0.entityRecordName == entity && [.boardTargetStatus, .boardTargetPriority].contains($0.action.kind)
        }
        writes = fieldWrites
        func pendingRequest(_ kind: ActionKind) -> [String: JSONValue]? {
            fieldWrites.last { $0.isPending && $0.pending.action.kind == kind }?.pending.action.params
        }
        let pendingStatus = pendingRequest(.boardTargetStatus).flatMap { try? BoardTargetStatusParams(wireParams: $0).status }
        let pendingPriority = pendingRequest(.boardTargetPriority).flatMap { try? BoardTargetPriorityParams(wireParams: $0).priority }
        let isGroup = target.childrenCount > 0
        status = BoardFieldPicker(
            selection: pendingStatus ?? target.status,
            options: Self.options(WorkbenchTargetStatus.editable, keeping: pendingStatus ?? target.status),
            isEnabled: !target.archived && !isGroup && pendingStatus == nil,
            caption: isGroup ? BoardWriteText.groupCaption : nil
        )
        priority = BoardFieldPicker(
            selection: pendingPriority ?? target.priority,
            options: Self.options(WorkbenchTargetPriority.knownValues, keeping: pendingPriority ?? target.priority),
            isEnabled: !target.archived && pendingPriority == nil,
            caption: nil
        )

        // A live target's archived children stay under Archive.
        let childTargets = snapshot.targets
            .filter { $0.parentID == target.id && $0.archived == target.archived }
            .sorted(by: BoardModel.boardOrder)
        children = childTargets.map { BoardRowModel($0, snapshot: snapshot) }
        childrenHeader = "Sub-targets · \(childTargets.filter { $0.status == .done }.count) / \(childTargets.count)"
        sessions = target.sessionIDs.compactMap(snapshot.session).map { SessionRowModel($0, now: now) }
        asks = snapshot.openAsks(in: target.workbenchID)
            .filter { $0.targetID == target.id }
            .map { WaitingCardModel($0, snapshot: snapshot, now: now) }

        let threads = Self.threads(Self.comments(of: target, in: snapshot), canReply: !target.archived, now: now)
        comments = threads.flatMap(\.rows)
        let replies = BoardWriteRow.rows(in: snapshot, now: now) { $0.action.kind == .boardCommentReply }
        let added = BoardWriteRow.rows(in: snapshot, now: now) { $0.action.kind == .boardCommentAdd && $0.entityRecordName == entity }
        thread = threads.flatMap { group in
            let rootName = SliceKind.workbenchComment.recordName(id: String(group.rootID))
            return group.rows.map(ThreadItem.comment)
                + replies.filter { $0.pending.entityRecordName == rootName }.map { ThreadItem.write($0, isReply: true) }
        } + added.map { ThreadItem.write($0, isReply: false) }
    }

    /// The editable values, plus the shown one when it is not among them
    /// (a snoozed target), so the picker always has its selection.
    private static func options<Value: Hashable>(_ editable: [Value], keeping shown: Value) -> [Value] {
        editable.contains(shown) ? editable : editable + [shown]
    }

    private static func breadcrumb(of target: WorkbenchTarget, in snapshot: WorkbenchReplicaSnapshot) -> [Crumb] {
        let board = snapshot.targets.filter { $0.workbenchID == target.workbenchID }
        let byID = Dictionary(board.map { ($0.id, $0) }) { first, _ in first }
        var crumbs: [Crumb] = []
        var seen: Set<Int64> = [target.id]
        var cursor = target.parentID.flatMap { byID[$0] }
        while let parent = cursor, seen.insert(parent.id).inserted {
            crumbs.insert(Crumb(id: parent.id, title: parent.text), at: 0)
            cursor = parent.parentID.flatMap { byID[$0] }
        }
        return crumbs
    }

    /// The target's comments, plus replies that name only their parent.
    private static func comments(of target: WorkbenchTarget, in snapshot: WorkbenchReplicaSnapshot) -> [WorkbenchComment] {
        let direct = snapshot.comments.filter { $0.targetID == target.id }
        let ids = Set(direct.map(\.id))
        return direct + snapshot.comments.filter { $0.targetID == nil && $0.parentID.map(ids.contains) == true }
    }

    /// Roots oldest first, each with its whole thread oldest first.
    private static func threads(
        _ comments: [WorkbenchComment], canReply: Bool, now: Date
    ) -> [(rootID: Int64, rows: [CommentRow])] {
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
        return roots.map { root in
            (root.id, (threads[root.id] ?? [root]).map { comment in
                CommentRow(
                    id: comment.id,
                    author: comment.author == .owner ? "You" : (comment.agentLabel.isEmpty ? "Agent" : comment.agentLabel),
                    body: comment.body,
                    age: CompactAge.string(from: comment.createdAt, now: now),
                    isReply: comment.id != root.id,
                    isResolved: comment.status == .resolved,
                    rootID: root.id,
                    canReply: canReply && comment.id == root.id
                )
            })
        }
    }

    var toneUses: [ToneUse] {
        row.toneUses + children.flatMap(\.toneUses) + sessions.flatMap(\.toneUses) + asks.map(\.toneUse)
    }
}
