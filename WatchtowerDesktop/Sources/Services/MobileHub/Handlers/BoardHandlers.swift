import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// The board writes from the phone (mobile POC spec §5.2, §6.3):
/// `board_target_status`, `board_target_priority`, `board_comment_add`,
/// `board_comment_reply` and `board_target_create`. Each runs the Desktop
/// board's own writer (`WorkbenchOwnerWrites`; a new target goes through Go's
/// `workbench target add`, the agent's writer with the owner as actor), and
/// reports every target it touched — the rolled-up parents too — through
/// `onOwnerWrite`, so the Mac never announces the owner's own phone edit.
///
/// Before any write, each kind re-checks the board scope (§5.2 rule 3): a
/// workbench or row that is gone is `not_found`, a row of another workbench
/// or of no board `not_on_board`. Status and priority carry the value the
/// phone showed (`from_*`): a different current value is `conflict` with
/// `result.current`, one already equal to the request is `applied` with no
/// write (rule 2). The checks and the write share one transaction.
///
/// The relay marks the non-idempotent kinds `begun` before they reach here
/// (rule 1). Every handler owns its timeout and never calls back into the
/// relay processor.
@MainActor
final class BoardHandlers {
    typealias OwnerWrite = @MainActor (Int64, WorkbenchSubject) -> Void

    /// Ample for a write waiting on the database lock or a CLI run.
    nonisolated static let defaultTimeout: Duration = .seconds(30)
    static let timeoutMessage = "The Mac did not finish this board change in time — check the board on the Mac"
    static let kinds: [ActionKind] = [
        .boardTargetStatus, .boardTargetPriority, .boardCommentAdd, .boardCommentReply, .boardTargetCreate
    ]
    /// Spec §5.2 caps. The title counts Unicode scalars, as Go's `target
    /// add` counts runes; comment bodies and the intent count characters.
    nonisolated static let bodyLimit = 4000
    nonisolated static let titleLimit = 200
    nonisolated static let intentLimit = 4000

    private let dbPool: DatabasePool
    private let cli: WorkbenchCLI?
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let onOwnerWrite: OwnerWrite
    private let isReporting: @MainActor () -> Bool

    init(
        dbPool: DatabasePool,
        cli: WorkbenchCLI?,
        timeout: Duration = BoardHandlers.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        isReporting: @escaping @MainActor () -> Bool = { true },
        onOwnerWrite: @escaping OwnerWrite
    ) {
        self.isReporting = isReporting
        self.dbPool = dbPool
        self.cli = cli
        self.timeout = timeout
        self.sleep = sleep
        self.onOwnerWrite = onOwnerWrite
    }

    func register(on dispatcher: MobileHubCommandDispatcher) {
        for kind in Self.kinds {
            dispatcher.register(kind) { try await self.handle($0) }
        }
    }

    /// The echo of one board action. A timeout is `outcome_unknown`: the
    /// write may still land (it is never cut mid-write). Without a board to
    /// report the write to (`isReporting` false: the workbenches view model
    /// is gone), the write would land unannounced and the Mac would notify
    /// the owner of their own phone edit: refused `write_failed`, nothing
    /// written.
    func handle(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard isReporting() else {
            return .failed(.writeFailed, message: "The Mac's board is not ready — try again in a moment")
        }
        return try await withHandlerTimeout(timeout, sleep: sleep, message: Self.timeoutMessage) {
            do {
                return try await self.apply(action)
            } catch let refusal as Refusal {
                return .failed(refusal.reason, message: refusal.message)
            }
        }
    }

    private func apply(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard case let .integer(workbenchID)? = action.params["workbench_id"] else {
            throw Refusal.invalid("\(action.kind.rawValue) needs a workbench_id")
        }
        let entityID = action.entityID.flatMap(Int64.init)
        switch action.kind {
        case .boardTargetStatus:
            return try await edit(.status, of: entityID, on: workbenchID, params: action.params)
        case .boardTargetPriority:
            return try await edit(.priority, of: entityID, on: workbenchID, params: action.params)
        case .boardCommentAdd:
            return try await addComment(on: entityID, in: workbenchID, params: action.params)
        case .boardCommentReply:
            return try await reply(to: entityID, in: workbenchID, params: action.params)
        case .boardTargetCreate:
            return try await createTarget(in: workbenchID, params: action.params)
        default:
            return .failed(.unsupportedInPOC)
        }
    }

    // MARK: - Status and priority

    private func edit(
        _ field: TargetField, of targetID: Int64?, on workbenchID: Int64, params: [String: JSONValue]
    ) async throws -> ActionOutcome {
        guard let targetID,
              case let .string(value)? = params[field.name],
              case let .string(shown)? = params["from_\(field.name)"] else {
            throw Refusal.invalid("board_target_\(field.name) needs a target id, \(field.name) and from_\(field.name)")
        }
        guard field.allowed.contains(value) else {
            throw Refusal.invalid("\(field.name) must be one of \(field.allowed.joined(separator: ", "))")
        }
        let edit = try await dbPool.write { db -> FieldEdit in
            let target = try Self.boardTarget(db, targetID, on: workbenchID)
            if field.refusesGroups, try Self.hasChildren(db, targetID, on: workbenchID) {
                throw Refusal.invalid("A group's status follows its sub-tasks")
            }
            let current = field.current(target)
            if current == value { return .unchanged }
            guard current == shown else { return .conflict(current: current) }
            return .wrote(try field.write(db, targetID, value))
        }
        switch edit {
        case .unchanged:
            break
        case let .conflict(current):
            return ActionOutcome(
                status: .failed, reason: .conflict, result: ["current": .string(current)],
                errorMessage: "Changed on the Mac to \(current)"
            )
        case let .wrote(write):
            report(write.touched, on: workbenchID)
        }
        return .applied([field.name: .string(value)])
    }

    // MARK: - Comments

    private func addComment(on targetID: Int64?, in workbenchID: Int64, params: [String: JSONValue]) async throws -> ActionOutcome {
        guard let targetID, case let .string(raw)? = params["body"] else {
            throw Refusal.invalid("board_comment_add needs a target id and a body")
        }
        let body = try Self.text(raw, named: "body", limit: Self.bodyLimit, count: \.count)
        let (id, write) = try await dbPool.write { db -> (commentID: Int64, write: WorkbenchOwnerWrite) in
            _ = try Self.boardTarget(db, targetID, on: workbenchID)
            return try WorkbenchOwnerWrites.addComment(db, projectID: workbenchID, targetID: targetID, body: body)
        }
        report(write.touched, on: workbenchID)
        return .applied(["comment_id": .integer(id)])
    }

    private func reply(to rootID: Int64?, in workbenchID: Int64, params: [String: JSONValue]) async throws -> ActionOutcome {
        guard let rootID, case let .string(raw)? = params["body"] else {
            throw Refusal.invalid("board_comment_reply needs a comment id and a body")
        }
        let body = try Self.text(raw, named: "body", limit: Self.bodyLimit, count: \.count)
        let (id, write) = try await dbPool.write { db -> (commentID: Int64, write: WorkbenchOwnerWrite) in
            try Self.requireWorkbench(db, workbenchID)
            guard let root = try WorkbenchComment.fetchOne(
                db, sql: "SELECT * FROM project_comments WHERE id = ?", arguments: [rootID]
            ) else { throw Refusal(reason: .notFound, message: "This comment no longer exists on the Mac") }
            guard root.projectID == workbenchID else {
                throw Refusal(reason: .notOnBoard, message: "That comment is not on this workbench's board")
            }
            guard root.isRoot else { throw Refusal.invalid("A reply goes under a thread's first comment") }
            return try WorkbenchOwnerWrites.reply(db, to: rootID, body: body)
        }
        report(write.touched, on: workbenchID)
        return .applied(["comment_id": .integer(id)])
    }

    // MARK: - New target

    private func createTarget(in workbenchID: Int64, params: [String: JSONValue]) async throws -> ActionOutcome {
        guard case let .string(rawTitle)? = params["text"], case let .string(priority)? = params["priority"] else {
            throw Refusal.invalid("board_target_create needs a text and a priority")
        }
        let title = try Self.text(rawTitle, named: "text", limit: Self.titleLimit, count: \.unicodeScalars.count)
        let intent = try Self.intent(params["intent"])
        let parentID = try Self.parentID(params["parent_id"])
        guard WorkbenchBoardCard.editablePriorities.contains(priority) else {
            throw Refusal.invalid("priority must be one of \(WorkbenchBoardCard.editablePriorities.joined(separator: ", "))")
        }
        let before = try await dbPool.read { db in try Self.chainStatuses(db, parentID, on: workbenchID) }
        guard let cli else { return .failed(.writeFailed, message: "The watchtower CLI is not available on the Mac") }
        let newID: Int64
        do {
            newID = try await cli.addTarget(
                workbenchID: workbenchID, title: title, intent: intent, priority: priority, parentID: parentID
            )
        } catch is DecodingError {
            // The command exited 0, so the target may well exist.
            return .failed(.outcomeUnknown, message: "The Mac could not read the new target's id — check the board on the Mac")
        } catch {
            return .failed(.writeFailed, message: error.localizedDescription)
        }
        // The parents the new child re-rolled (PROJ-05) are the owner's doing.
        let after = try await dbPool.read { db in try Self.chainStatuses(db, parentID, on: workbenchID) }
        report([newID] + after.filter { before[$0.key] != $0.value }.map(\.key).sorted(), on: workbenchID)
        return .applied(["target_id": .integer(newID)])
    }

    // MARK: - Helpers

    private func report(_ targetIDs: [Int64], on workbenchID: Int64) {
        for id in targetIDs {
            onOwnerWrite(workbenchID, .target(id))
        }
    }

    /// Trimmed, non-empty and within `limit` as `count` measures it.
    nonisolated private static func text(
        _ raw: String, named name: String, limit: Int, count: (String) -> Int
    ) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Refusal.invalid("\(name) is empty") }
        guard count(text) <= limit else { throw Refusal.invalid("\(name) is longer than \(limit) characters") }
        return text
    }

    nonisolated private static func intent(_ value: JSONValue?) throws -> String {
        switch value {
        case nil, .null?: return ""
        case let .string(raw)?:
            let intent = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard intent.count <= intentLimit else { throw Refusal.invalid("intent is longer than \(intentLimit) characters") }
            return intent
        default: throw Refusal.invalid("intent must be text")
        }
    }

    nonisolated private static func parentID(_ value: JSONValue?) throws -> Int64? {
        switch value {
        case nil, .null?: return nil
        case let .integer(id)?: return id
        default: throw Refusal.invalid("parent_id must be a target id")
        }
    }

    nonisolated private static func requireWorkbench(_ db: Database, _ workbenchID: Int64) throws {
        guard try WorkbenchQueries.fetch(db, id: workbenchID) != nil else {
            throw Refusal(reason: .notFound, message: "This workbench no longer exists on the Mac")
        }
    }

    /// The target, when it is on `workbenchID`'s board (§5.2 rule 3).
    nonisolated private static func boardTarget(_ db: Database, _ targetID: Int64, on workbenchID: Int64) throws -> Target {
        try requireWorkbench(db, workbenchID)
        guard let target = try TargetQueries.fetchByID(db, id: Int(targetID)) else {
            throw Refusal(reason: .notFound, message: "This target no longer exists on the Mac")
        }
        guard target.workbenchID == workbenchID else {
            throw Refusal(reason: .notOnBoard, message: "That target is not on this workbench's board")
        }
        return target
    }

    /// A group: children on the same board, the PROJ-05 rollup's own rule.
    nonisolated private static func hasChildren(_ db: Database, _ targetID: Int64, on workbenchID: Int64) throws -> Bool {
        try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM targets WHERE parent_id = ? AND project_id = ?)",
            arguments: [targetID, workbenchID]
        ) ?? false
    }

    /// The statuses of `parentID` and its ancestors (empty without a
    /// parent), after checking the workbench and the parent's board.
    nonisolated private static func chainStatuses(_ db: Database, _ parentID: Int64?, on workbenchID: Int64) throws -> [Int64: String] {
        guard let parentID else {
            try requireWorkbench(db, workbenchID)
            return [:]
        }
        let parent = try boardTarget(db, parentID, on: workbenchID)
        var statuses = try WorkbenchQueries.ancestorStatuses(db, of: parentID)
        statuses[parentID] = parent.status
        return statuses
    }
}

/// A refusal with its echo reason, thrown inside a check or a transaction
/// (rolling it back) and answered as `failed`.
private struct Refusal: Error {
    let reason: ActionReason
    let message: String

    static func invalid(_ message: String) -> Self {
        Self(reason: .invalidParams, message: message)
    }
}

/// What a status or priority action found and did.
private enum FieldEdit: Sendable {
    case unchanged
    case conflict(current: String)
    case wrote(WorkbenchOwnerWrite)
}

/// The target column a status or priority action edits.
private struct TargetField: Sendable {
    let name: String
    let allowed: [String]
    /// PROJ-05: a group's status follows its sub-tasks.
    let refusesGroups: Bool
    let current: @Sendable (Target) -> String
    let write: @Sendable (Database, Int64, String) throws -> WorkbenchOwnerWrite

    static let status = Self(
        name: "status", allowed: WorkbenchBoardCard.editableStatuses, refusesGroups: true,
        current: { $0.status },
        write: { try WorkbenchOwnerWrites.setStatus($0, targetID: $1, status: $2) }
    )

    static let priority = Self(
        name: "priority", allowed: WorkbenchBoardCard.editablePriorities, refusesGroups: false,
        current: { $0.priority },
        write: { try WorkbenchOwnerWrites.setPriority($0, targetID: $1, priority: $2) }
    )
}
