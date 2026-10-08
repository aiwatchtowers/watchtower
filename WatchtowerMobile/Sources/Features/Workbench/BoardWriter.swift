import Foundation
import Observation
import WatchtowerKit
import WatchtowerSync

/// Sends the phone's board writes (spec §5.2, §6.3) through the outbox:
/// status, priority, comments, replies and new targets, and resolves a
/// conflict. `from_status`/`from_priority` are always the replica's value
/// the phone shows, never an optimistic one. Owned by `AppEnvironment`.
///
/// One write per field (or per comment target) is in flight at a time:
/// until the outbox has saved the action and its overlay row, a second
/// send on the same key is a no-op, so a double tap never posts a
/// non-idempotent comment twice and two picks never stack on one field.
@MainActor
@Observable
final class BoardWriter {
    typealias Enqueue = (ActionKind, String?, [String: JSONValue]) async throws -> Void

    /// Keys (`BoardWriter.key`) of the sends still waiting for the outbox.
    private(set) var inFlight: Set<String> = []

    @ObservationIgnored private let enqueue: Enqueue
    @ObservationIgnored private let remove: (String) throws -> Void
    /// The failed overlay rows of one kind on one entity (ids).
    @ObservationIgnored private let failedRows: (ActionKind, String) throws -> [String]

    init(
        enqueue: @escaping Enqueue,
        remove: @escaping (String) throws -> Void,
        failedRows: @escaping (ActionKind, String) throws -> [String] = { _, _ in [] }
    ) {
        self.enqueue = enqueue
        self.remove = remove
        self.failedRows = failedRows
    }

    /// The app's writer: actions through the outbox, Dismiss on the overlay.
    static func sending(through outbox: ActionOutbox, store: ReplicaStore) -> BoardWriter {
        BoardWriter(
            enqueue: { kind, entity, params in
                try await outbox.enqueue(kind: kind, entityRecordName: entity, params: params)
            },
            remove: { try store.removePendingAction(id: $0) },
            failedRows: { kind, entity in
                try store.pendingActions(forEntity: entity)
                    .filter { $0.state == .failed && $0.action.kind == kind }
                    .map(\.id)
            }
        )
    }

    /// The in-flight key of a kind on an entity (nil for a new target).
    nonisolated static func key(_ kind: ActionKind, _ entity: String?) -> String {
        "\(kind.rawValue)|\(entity ?? "")"
    }

    /// Asks the Mac to set the status; the shown value sends nothing.
    func setStatus(_ status: WorkbenchTargetStatus, on target: WorkbenchTarget) async throws {
        guard status != target.status else { return }
        let params = BoardTargetStatusParams(workbenchID: target.workbenchID, status: status, fromStatus: target.status)
        try await sendField(BoardTargetStatusParams.actionKind, Self.recordName(target), try params.wireParams())
    }

    /// Asks the Mac to set the priority; the shown value sends nothing.
    func setPriority(_ priority: WorkbenchTargetPriority, on target: WorkbenchTarget) async throws {
        guard priority != target.priority else { return }
        let params = BoardTargetPriorityParams(workbenchID: target.workbenchID, priority: priority, fromPriority: target.priority)
        try await sendField(BoardTargetPriorityParams.actionKind, Self.recordName(target), try params.wireParams())
    }

    /// Adds a comment to the target; whitespace only, or a comment already
    /// on its way, sends nothing (false).
    @discardableResult
    func addComment(_ body: String, on target: WorkbenchTarget) async throws -> Bool {
        guard let body = CommentDraft.trimmed(body) else { return false }
        let params = BoardCommentAddParams(workbenchID: target.workbenchID, body: body)
        return try await send(BoardCommentAddParams.actionKind, Self.recordName(target), try params.wireParams())
    }

    /// Replies under a thread's root (a resolved root too: the Mac reopens
    /// it); whitespace only, or a reply already on its way, sends nothing
    /// (false).
    @discardableResult
    func reply(_ body: String, toRoot rootID: Int64, workbenchID: Int64) async throws -> Bool {
        guard let body = CommentDraft.trimmed(body) else { return false }
        let params = BoardCommentReplyParams(workbenchID: workbenchID, body: body)
        return try await send(
            BoardCommentReplyParams.actionKind,
            SliceKind.workbenchComment.recordName(id: String(rootID)),
            try params.wireParams()
        )
    }

    /// Asks the Mac to add the target; an empty title sends nothing (false).
    @discardableResult
    func create(_ draft: NewBoardTargetDraft) async throws -> Bool {
        guard let params = try draft.params() else { return false }
        return try await send(BoardTargetCreateParams.actionKind, nil, params)
    }

    /// "Apply anyway" on a conflict: a new action with the same requested
    /// value and the Mac's current value as `from_*`; the failed row goes
    /// with the field's other failures. A row that is not a conflict does
    /// nothing.
    func applyAnyway(_ row: BoardWriteRow) async throws {
        guard let current = row.conflictCurrent, let entity = row.pending.entityRecordName else { return }
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
        try await sendField(action.kind, entity, params)
    }

    /// Dismiss on a failed row, and No on a conflict.
    func dismiss(_ row: BoardWriteRow) throws {
        try remove(row.id)
    }

    /// A status or priority write: once it is queued, the field's older
    /// failed and conflict rows go, so a stale "apply anyway" can never
    /// send an older value over the newer one.
    private func sendField(_ kind: ActionKind, _ entity: String, _ params: [String: JSONValue]) async throws {
        let stale = try failedRows(kind, entity)
        guard try await send(kind, entity, params) else { return }
        for id in stale {
            try remove(id)
        }
    }

    /// Enqueues unless the same key is already in flight; returns whether
    /// it sent.
    private func send(_ kind: ActionKind, _ entity: String?, _ params: [String: JSONValue]) async throws -> Bool {
        let key = Self.key(kind, entity)
        guard inFlight.insert(key).inserted else { return false }
        defer { inFlight.remove(key) }
        try await enqueue(kind, entity, params)
        return true
    }

    private static func recordName(_ target: WorkbenchTarget) -> String {
        SliceKind.workbenchTarget.recordName(id: String(target.id))
    }
}
