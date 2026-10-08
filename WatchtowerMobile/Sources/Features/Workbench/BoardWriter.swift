import Foundation
import WatchtowerKit
import WatchtowerSync

/// Sends the phone's board writes (spec §5.2, §6.3) through the outbox:
/// status, priority, comments, replies and new targets, and resolves a
/// conflict. `from_status`/`from_priority` are always the replica's value
/// the phone shows, never an optimistic one. Owned by `AppEnvironment`.
@MainActor
final class BoardWriter {
    typealias Enqueue = (ActionKind, String?, [String: JSONValue]) async throws -> Void

    private let enqueue: Enqueue
    private let remove: (String) throws -> Void

    init(enqueue: @escaping Enqueue, remove: @escaping (String) throws -> Void) {
        self.enqueue = enqueue
        self.remove = remove
    }

    /// The app's writer: actions through the outbox, Dismiss on the overlay.
    static func sending(through outbox: ActionOutbox, store: ReplicaStore) -> BoardWriter {
        BoardWriter(
            enqueue: { kind, entity, params in
                try await outbox.enqueue(kind: kind, entityRecordName: entity, params: params)
            },
            remove: { try store.removePendingAction(id: $0) }
        )
    }

    /// Asks the Mac to set the status; the shown value sends nothing.
    func setStatus(_ status: WorkbenchTargetStatus, on target: WorkbenchTarget) async throws {
        guard status != target.status else { return }
        let params = BoardTargetStatusParams(workbenchID: target.workbenchID, status: status, fromStatus: target.status)
        try await enqueue(BoardTargetStatusParams.actionKind, Self.recordName(target), try params.wireParams())
    }

    /// Asks the Mac to set the priority; the shown value sends nothing.
    func setPriority(_ priority: WorkbenchTargetPriority, on target: WorkbenchTarget) async throws {
        guard priority != target.priority else { return }
        let params = BoardTargetPriorityParams(workbenchID: target.workbenchID, priority: priority, fromPriority: target.priority)
        try await enqueue(BoardTargetPriorityParams.actionKind, Self.recordName(target), try params.wireParams())
    }

    /// Adds a comment to the target; whitespace only sends nothing (false).
    @discardableResult
    func addComment(_ body: String, on target: WorkbenchTarget) async throws -> Bool {
        guard let body = CommentDraft.trimmed(body) else { return false }
        let params = BoardCommentAddParams(workbenchID: target.workbenchID, body: body)
        try await enqueue(BoardCommentAddParams.actionKind, Self.recordName(target), try params.wireParams())
        return true
    }

    /// Replies under a thread's root (a resolved root too: the Mac reopens
    /// it); whitespace only sends nothing (false).
    @discardableResult
    func reply(_ body: String, toRoot rootID: Int64, workbenchID: Int64) async throws -> Bool {
        guard let body = CommentDraft.trimmed(body) else { return false }
        let params = BoardCommentReplyParams(workbenchID: workbenchID, body: body)
        try await enqueue(
            BoardCommentReplyParams.actionKind,
            SliceKind.workbenchComment.recordName(id: String(rootID)),
            try params.wireParams()
        )
        return true
    }

    /// Asks the Mac to add the target; an empty title sends nothing (false).
    @discardableResult
    func create(_ draft: NewBoardTargetDraft) async throws -> Bool {
        guard let params = try draft.params() else { return false }
        try await enqueue(BoardTargetCreateParams.actionKind, nil, params)
        return true
    }

    /// "Apply anyway" on a conflict: a new action with the same requested
    /// value and the Mac's current value as `from_*`, then the failed row
    /// goes. A row that is not a conflict does nothing.
    func applyAnyway(_ row: BoardWriteRow) async throws {
        guard let current = row.conflictCurrent else { return }
        let action = row.pending.action
        let params: [String: JSONValue]
        switch action.kind {
        case .boardTargetStatus:
            let request = try BoardTargetStatusParams(wireParams: action.params)
            params = try BoardTargetStatusParams(
                workbenchID: request.workbenchID, status: request.status, fromStatus: WorkbenchTargetStatus(rawValue: current)
            ).wireParams()
        case .boardTargetPriority:
            let request = try BoardTargetPriorityParams(wireParams: action.params)
            params = try BoardTargetPriorityParams(
                workbenchID: request.workbenchID, priority: request.priority, fromPriority: WorkbenchTargetPriority(rawValue: current)
            ).wireParams()
        default:
            return
        }
        try await enqueue(action.kind, row.pending.entityRecordName, params)
        try remove(row.id)
    }

    /// Dismiss on a failed row, and No on a conflict.
    func dismiss(_ row: BoardWriteRow) throws {
        try remove(row.id)
    }

    private static func recordName(_ target: WorkbenchTarget) -> String {
        SliceKind.workbenchTarget.recordName(id: String(target.id))
    }
}
