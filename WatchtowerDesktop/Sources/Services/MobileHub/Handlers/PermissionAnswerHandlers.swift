import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// `permission_answer` and `session_interrupt` from the phone (#517, spec
/// 2026-10-17-phone-permission-answers §5.3, §6).
///
/// `permission_answer` (entity: the session id; params `{request_id,
/// behavior: allow|deny}`) decides one `permission_requests` row that the
/// session's waiting `permission-wait` hook polls. Order: the device's own
/// `permissions_allowed` grant (never implied by typing; else
/// `device_not_allowed`) → the row is this live board Claude session's
/// (else `not_found`) and `pending` (else `not_pending`, its message naming
/// why) → an allow the phone may give (`PermissionAllowBlock`: never for a
/// shortened summary nor an Edit/Write/NotebookEdit of a settings path;
/// else `answer_on_mac`, the row left pending; a deny always may) → the
/// session runs (else `session_not_running`) → one guarded
/// `UPDATE … WHERE status = 'pending'`, so a Mac answer or a second phone
/// that got there first leaves this one `not_pending`. Only the hook's JSON
/// decides the prompt: nothing is typed into the terminal (PROJ-16 holds).
///
/// `session_interrupt` (entity: the session id) is one Esc through the
/// app's input path. Order: `typing_allowed` → a board Claude session →
/// running → its resolved state is Working (Agents working included; never
/// Running, which is no turn reported, and never Needs approval: an Esc
/// must not answer a prompt; else `not_working`) → the action at most
/// `interruptMaxAge` old at `now` (else `expired`: an Esc must not land on
/// a later turn the owner never saw).
///
/// Neither is ever held or retried: the relay claims both `begun` before
/// the handler (`RelayProcessor.nonIdempotentKinds`), and a prompt or turn
/// that is gone stays gone. Each handler owns its timeout.
@MainActor
final class PermissionAnswerHandlers {
    typealias DeviceName = @MainActor (_ deviceID: String?) -> String?

    static let kinds: [ActionKind] = [.permissionAnswer, .sessionInterrupt]
    /// The oldest interrupt the hub still sends.
    static let interruptMaxAge: TimeInterval = 120
    nonisolated static let defaultTimeout: Duration = .seconds(30)
    static let timeoutMessage = "The Mac did not finish this in time — check the session on the Mac"
    static let answeredOnMacMessage = "Answered on the Mac"
    static let tooLateMessage = "Too late — answer on the Mac"
    static let notFoundMessage = "This session no longer exists on the Mac"
    static let needsApprovalMessage = "A permission prompt may be open — answer it on the Mac or with Deny"
    static let notRunningMessage = "This session is not running on the Mac"
    /// `decided_by` when the device's name cannot be read.
    static let unnamedDevice = "phone"

    private let dbPool: DatabasePool
    private let terminalCenter: TerminalCenter
    private let status: SessionInputHandlers.Status
    private let deviceGrant: SessionStartStopHandlers.Grant
    private let deviceName: DeviceName
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        dbPool: DatabasePool,
        terminalCenter: TerminalCenter,
        status: @escaping SessionInputHandlers.Status,
        deviceGrant: @escaping SessionStartStopHandlers.Grant,
        deviceName: @escaping DeviceName,
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = PermissionAnswerHandlers.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.terminalCenter = terminalCenter
        self.status = status
        self.deviceGrant = deviceGrant
        self.deviceName = deviceName
        self.now = now
        self.timeout = timeout
        self.sleep = sleep
    }

    func register(on dispatcher: MobileHubCommandDispatcher) {
        for kind in Self.kinds {
            dispatcher.register(kind) { try await self.handle($0) }
        }
    }

    /// The echo of one action; a timeout is `outcome_unknown`.
    func handle(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        try await withHandlerTimeout(timeout, sleep: sleep, message: Self.timeoutMessage) {
            switch action.kind {
            case .permissionAnswer: try await self.answer(action)
            case .sessionInterrupt: try await self.interrupt(action)
            default: .failed(.unsupportedInPOC)
            }
        }
    }

    // MARK: - Answer

    private func answer(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard let sessionID = action.entityID.flatMap(Int64.init),
              case let .integer(requestID)? = action.params["request_id"],
              case let .string(rawBehavior)? = action.params["behavior"] else {
            return .failed(.invalidParams, message: "permission_answer needs a session id, request_id and behavior")
        }
        let decided: String
        switch rawBehavior {
        case "allow": decided = "allowed"
        case "deny": decided = "denied"
        default: return .failed(.invalidParams, message: "behavior must be allow or deny")
        }
        guard deviceGrant(action.deviceID).permissionsAllowed else {
            return .failed(.deviceNotAllowed, message: "This phone is not allowed to answer permission prompts")
        }
        guard try await isBoardSession(sessionID),
              let current = try await storedRequest(requestID, sessionID: sessionID) else {
            return .failed(.notFound, message: "This permission request no longer exists on the Mac")
        }
        guard current.status == "pending" else { return Self.notPending(current.status) }
        if rawBehavior == "allow", let block = current.allowBlock {
            return .failed(.answerOnMac, message: block.note)
        }
        guard terminalCenter.liveIDs.contains(sessionID) else {
            return .failed(.sessionNotRunning, message: Self.notRunningMessage)
        }
        let stamp = SessionAgentStatus.formatStamp(now())
        let name = deviceName(action.deviceID) ?? Self.unnamedDevice
        // One short write: the guard keeps an answer that landed since the read.
        let changed = try await dbPool.write { db -> Int in
            try db.execute(
                sql: """
                    UPDATE permission_requests SET status = ?, decided_at = ?, decided_by = ?
                    WHERE id = ? AND terminal_session_id = ? AND status = 'pending'
                    """,
                arguments: [decided, stamp, name, requestID, sessionID]
            )
            return db.changesCount
        }
        guard changed == 1 else {
            let after = try await storedRequest(requestID, sessionID: sessionID)
            return Self.notPending(after?.status ?? "")
        }
        return .applied(["status": .string(decided)])
    }

    /// What an answer needs of a stored request.
    private struct StoredRequest {
        let status: String
        /// Why the phone may only deny it; nil when it may allow it.
        let allowBlock: PermissionAllowBlock?
    }

    /// The row when it is `sessionID`'s request; nil otherwise. Shortened
    /// as the phone saw it: Go's flag or the slice's own cap.
    private func storedRequest(_ requestID: Int64, sessionID: Int64) async throws -> StoredRequest? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT status, tool_name, summary, summary_clipped FROM permission_requests
                    WHERE id = ? AND terminal_session_id = ?
                    """,
                arguments: [requestID, sessionID]
            ) else { return nil }
            let raw: String = row["summary"]
            let clipped = PermissionRequestSlice.wireSummary(raw, clippedByGo: row["summary_clipped"]).clipped
            let toolName: String = row["tool_name"]
            return StoredRequest(
                status: row["status"],
                allowBlock: PermissionAllowBlock.check(toolName: toolName, summary: raw, clipped: clipped)
                    ?? Self.resolvedSettingsPath(toolName: toolName, path: raw)
            )
        }
    }

    /// The Mac also checks the path with its symlinks resolved: a file or
    /// folder linked into `.claude` must not read as an ordinary one. The
    /// phone cannot resolve it, so only the hub refuses such an allow.
    nonisolated static func resolvedSettingsPath(toolName: String, path: String) -> PermissionAllowBlock? {
        guard PermissionAllowBlock.pathTools.contains(toolName), path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        // An existing file resolves whole; the file a Write creates does
        // not exist yet, and Foundation then resolves nothing: resolve the
        // folder and keep the name.
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let candidates = [url.resolvingSymlinksInPath().path, folder.appendingPathComponent(url.lastPathComponent).path]
        return candidates.lazy
            .compactMap { PermissionAllowBlock.check(toolName: toolName, summary: $0, clipped: false) }
            .first
    }

    /// `not_pending` with a message the phone shows as it is.
    static func notPending(_ status: String) -> ActionOutcome {
        let message = switch status {
        case "answered_on_mac": answeredOnMacMessage
        case "expired": tooLateMessage
        case "allowed": "Already allowed from a phone"
        case "denied": "Already denied from a phone"
        default: "This prompt is no longer waiting for an answer"
        }
        return .failed(.notPending, message: message)
    }

    // MARK: - Interrupt

    private func interrupt(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard let sessionID = action.entityID.flatMap(Int64.init) else {
            return .failed(.invalidParams, message: "session_interrupt needs a session id")
        }
        guard deviceGrant(action.deviceID).typingAllowed else {
            return .failed(.deviceNotAllowed, message: "This phone is not allowed to type into sessions")
        }
        guard try await isBoardSession(sessionID) else { return .failed(.notFound, message: Self.notFoundMessage) }
        guard terminalCenter.liveIDs.contains(sessionID) else {
            return .failed(.sessionNotRunning, message: Self.notRunningMessage)
        }
        guard let current = status(sessionID), Self.isWorking(current) else {
            return .failed(.notWorking, message: "The agent is not working right now")
        }
        guard now().timeIntervalSince(action.createdAt) <= Self.interruptMaxAge else { return .expired }
        // Claude Code draws a prompt before its hook reports it, so the
        // state above may still say Working: a pending request means a
        // prompt is on screen, and an Esc would reject it (spec §6).
        guard try await !hasPendingRequest(sessionID) else {
            return .failed(.notWorking, message: Self.needsApprovalMessage)
        }
        guard terminalCenter.sendInterrupt(sessionID: sessionID) else {
            return .failed(.sessionNotRunning, message: Self.notRunningMessage)
        }
        return .applied()
    }

    private func hasPendingRequest(_ sessionID: Int64) async throws -> Bool {
        try await dbPool.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM permission_requests WHERE terminal_session_id = ? AND status = 'pending')",
                arguments: [sessionID]
            ) ?? false
        }
    }

    /// Working for an interrupt: a live session whose current turn works,
    /// or whose background agents do (Agents working).
    static func isWorking(_ status: SessionAgentStatus) -> Bool {
        guard status.state.live else { return false }
        switch status.state.kind {
        case .working, .background: return true
        case .notStarted, .running, .needsApproval, .stopped, .finished, .waitingOnAsk, .readyToCheck, .failed:
            return false
        }
    }

    // MARK: - Scope

    /// A board `claude` session of a workbench that still exists: the phone
    /// sees nothing else, and Codex keeps "Needs approval on the Mac".
    private func isBoardSession(_ sessionID: Int64) async throws -> Bool {
        try await dbPool.read { try TerminalSessionQueries.fetchBoardSession($0, id: sessionID)?.kind == .claude }
    }
}
