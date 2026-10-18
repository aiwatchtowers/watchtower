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
    static let notWorkingMessage = "The agent is not working right now"
    /// `decided_by` when the device's name cannot be read.
    static let unnamedDevice = "phone"

    private let dbPool: DatabasePool
    private let terminalCenter: TerminalCenter
    private let control: SessionControl
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
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        control: SessionControl? = nil
    ) {
        self.dbPool = dbPool
        self.terminalCenter = terminalCenter
        // The app passes its shared one; alone (tests) a private one over
        // the same session state does the same checks (it types no line).
        self.control = control ?? SessionControl(
            dbPool: dbPool, terminalCenter: terminalCenter,
            lineDelivery: SessionLineDelivery(terminalCenter: terminalCenter), status: status, now: now
        )
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
        let allow: Bool
        switch rawBehavior {
        case "allow": allow = true
        case "deny": allow = false
        default: return .failed(.invalidParams, message: "behavior must be allow or deny")
        }
        guard deviceGrant(action.deviceID).permissionsAllowed else {
            return .failed(.deviceNotAllowed, message: "This phone is not allowed to answer permission prompts")
        }
        let notFound = ActionOutcome.failed(.notFound, message: "This permission request no longer exists on the Mac")
        guard try await isBoardSession(sessionID) else { return notFound }
        let name = deviceName(action.deviceID) ?? Self.unnamedDevice
        switch try await control.answerPermission(requestID: requestID, sessionID: sessionID, allow: allow, decidedBy: name) {
        case let .applied(decided): return .applied(["status": .string(decided)])
        case .notFound: return notFound
        case let .notPending(status): return Self.notPending(status)
        case let .allowBlocked(block): return .failed(.answerOnMac, message: block.note)
        case .notRunning: return .failed(.sessionNotRunning, message: Self.notRunningMessage)
        }
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
        // Running and Working come before the action's age, as the phone's
        // reasons always did; `control.interrupt` checks both again in the
        // same main-actor turn, so they cannot differ.
        guard terminalCenter.liveIDs.contains(sessionID) else {
            return .failed(.sessionNotRunning, message: Self.notRunningMessage)
        }
        guard let current = status(sessionID), SessionControl.isWorking(current) else {
            return .failed(.notWorking, message: Self.notWorkingMessage)
        }
        guard now().timeIntervalSince(action.createdAt) <= Self.interruptMaxAge else { return .expired }
        switch try await control.interrupt(sessionID) {
        case .sent: return .applied()
        case .notRunning: return .failed(.sessionNotRunning, message: Self.notRunningMessage)
        case .notWorking: return .failed(.notWorking, message: Self.notWorkingMessage)
        case .awaitingApproval: return .failed(.notWorking, message: Self.needsApprovalMessage)
        }
    }

    // MARK: - Scope

    /// A board `claude` session of a workbench that still exists: the phone
    /// sees nothing else, and Codex keeps "Needs approval on the Mac".
    private func isBoardSession(_ sessionID: Int64) async throws -> Bool {
        try await dbPool.read { try TerminalSessionQueries.fetchBoardSession($0, id: sessionID)?.kind == .claude }
    }
}
