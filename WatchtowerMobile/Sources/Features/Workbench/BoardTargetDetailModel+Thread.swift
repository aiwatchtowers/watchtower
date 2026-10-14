import Foundation
import WatchtowerKit
import WatchtowerSync

extension BoardTargetDetailModel {
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

    /// The comment rows and the thread as drawn: each root's thread with
    /// the phone's replies under it, then orphaned replies, then the phone's
    /// own new comments.
    static func commentThread(
        of target: WorkbenchTarget, entity: String, in snapshot: WorkbenchReplicaSnapshot, now: Date
    ) -> (comments: [CommentRow], thread: [ThreadItem]) {
        let threads = Self.threads(Self.comments(of: target, in: snapshot), canReply: !target.archived, now: now)
        let comments = threads.flatMap(\.rows)
        let replies = BoardWriteRow.rows(in: snapshot, now: now) {
            $0.action.kind == .boardCommentReply && Self.replyTarget(of: $0, in: snapshot) == target.id
        }
        let added = BoardWriteRow.rows(in: snapshot, now: now) { $0.action.kind == .boardCommentAdd && $0.entityRecordName == entity }
        let rootNames = Set(threads.map { SliceKind.workbenchComment.recordName(id: String($0.rootID)) })
        var items: [ThreadItem] = []
        for group in threads {
            let rootName = SliceKind.workbenchComment.recordName(id: String(group.rootID))
            items += group.rows.map(ThreadItem.comment)
            items += replies.filter { $0.pending.entityRecordName == rootName }.map { ThreadItem.write($0, isReply: true) }
        }
        // A reply whose root is not a shown thread's (pruned from the
        // replica, say) still shows, so a failure can be dismissed.
        items += replies.filter { !rootNames.contains($0.pending.entityRecordName ?? "") }.map { ThreadItem.write($0, isReply: true) }
        items += added.map { ThreadItem.write($0, isReply: false) }
        return (comments, items)
    }

    /// The target a reply belongs to: its root's, or else a sibling reply's
    /// (the root itself may have been pruned from the replica); nil when
    /// the replica has neither.
    static func replyTarget(of action: PendingAction, in snapshot: WorkbenchReplicaSnapshot) -> Int64? {
        guard let rootID = action.action.entityID.flatMap(Int64.init) else { return nil }
        if let root = snapshot.comments.first(where: { $0.id == rootID }), let targetID = root.targetID {
            return targetID
        }
        return snapshot.comments.first { $0.parentID == rootID && $0.targetID != nil }?.targetID
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
                    // The hub replies only under a real root (no parent): a
                    // reply whose root was pruned is shown as a root but
                    // offers no Reply.
                    canReply: canReply && comment.id == root.id && comment.parentID == nil
                )
            })
        }
    }
}
