import Foundation
import Observation
import WatchtowerKit
import WatchtowerSync

/// Sends the phone's board writes (spec §5.2, §6.3) through the outbox:
/// status, priority, comments, replies and new targets, and resolves a
/// conflict; and runs of the workbench's automations (ask #692). `from_status`/`from_priority` are always the replica's value
/// the phone shows, never an optimistic one. Owned by `AppEnvironment`.
///
/// A comment or reply the Mac applied stays in its thread
/// (`postedComments`) until the Mac's comment record reaches the replica:
/// the applied echo drops the pending row first (#1192).
///
/// One write per field (or per comment target) is in flight at a time
/// (`SendGuard`): a double tap never posts a non-idempotent comment twice
/// and two picks never stack on one field.
@MainActor
@Observable
final class BoardWriter {
    typealias Enqueue = (ActionKind, String?, [String: JSONValue]) async throws -> Void

    /// Keys (`BoardWriter.key`) of the sends still waiting for the outbox.
    var inFlight: Set<String> { sendGuard.inFlight }
    /// The comments and replies the Mac applied this run, newest last.
    private(set) var postedComments: [PostedComment] = []

    @ObservationIgnored private let sendGuard = SendGuard()
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

    /// An `applied` echo of a comment or reply: kept with the Mac's
    /// comment id until the record arrives. Other kinds are not ours.
    func receiveApplied(_ action: ActionRequestPayload, now: Date = Date()) {
        guard case let .integer(commentID)? = action.result?["comment_id"],
              let entity = action.entityID.flatMap(Int64.init),
              !postedComments.contains(where: { $0.commentID == commentID }) else { return }
        let posted: PostedComment
        switch action.kind {
        case .boardCommentAdd:
            guard let params = try? BoardCommentAddParams(wireParams: action.params) else { return }
            posted = PostedComment(commentID: commentID, targetID: entity, rootID: nil, body: params.body, postedAt: now)
        case .boardCommentReply:
            guard let params = try? BoardCommentReplyParams(wireParams: action.params) else { return }
            posted = PostedComment(commentID: commentID, targetID: nil, rootID: entity, body: params.body, postedAt: now)
        default:
            return
        }
        postedComments.removeAll { now.timeIntervalSince($0.postedAt) > PostedComment.keepFor }
        postedComments.append(posted)
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

    /// Asks the Mac to run the automation now (ask #692). `confirmed`: the
    /// owner pressed Run in the phone's confirmation (a `confirm: true` recipe
    /// runs only with it). A second tap while this one is still being saved
    /// sends nothing (false); once queued, the screen shows the run as sending
    /// and offers no Run. Its older failed rows go once it is queued.
    @discardableResult
    func runAutomation(_ automation: WorkbenchAutomation, workbenchID: Int64, confirmed: Bool = false) async throws -> Bool {
        let entity = Self.automationRecordName(automation.id)
        let stale = try failedRows(.automationRun, entity)
        let params = try AutomationRunParams(workbenchID: workbenchID, confirmed: confirmed).wireParams()
        guard try await send(.automationRun, entity, params) else { return false }
        for id in stale {
            try remove(id)
        }
        return true
    }

    /// Dismiss on the Mac's refusal of a run.
    func dismissRun(_ failure: WorkbenchAutomationsModel.Failure) throws {
        try remove(failure.pending.id)
    }

    /// The `automation_run` entity: the hub reads the id after the hyphen.
    nonisolated static func automationRecordName(_ id: Int64) -> String {
        "automation-\(id)"
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
        try await sendGuard.run(Self.key(kind, entity)) { try await enqueue(kind, entity, params) }
    }

    private static func recordName(_ target: WorkbenchTarget) -> String {
        SliceKind.workbenchTarget.recordName(id: String(target.id))
    }
}
