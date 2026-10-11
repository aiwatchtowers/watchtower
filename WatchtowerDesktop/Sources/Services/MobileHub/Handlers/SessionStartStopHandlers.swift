import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// `session_start` and `session_stop` from the phone (mobile POC spec §5.2,
/// §6.5).
///
/// `session_start` (entity: the target id; params `{workbench_id, mode,
/// plan_first, bring_forward, brief?}`) runs the Desktop's own start,
/// `WorkbenchesViewModel.startForTarget`: Work on it's read, reuse rule and
/// launch path. The brief is the work-on prompt, or the phone's `brief`
/// when the request's device may type; `plan_first` adds
/// `TerminalLaunch.planFirstSuffix`. Both apply to a new session only: an
/// `open_existing` that finds the target's session resumes its
/// conversation, and the echo carries that session's id (the Kit has no
/// result key to say it was reused). "Bring the window forward" off starts
/// in `.background`; on is Work on it's `.keeping(.board)` after the
/// workbench window comes to the front. A start is `applied` with
/// `{session_id, stage: starting}` once the process runs and did not exit
/// 127 (no Claude Code on the login shell's PATH, `claude_not_found`)
/// within `launchWatch`.
///
/// `session_stop` (entity: the session id) is `TerminalCenter.close`:
/// SIGHUP, then SIGKILL after the grace. Idempotent: a session that is not
/// live is `applied` with no signal.
///
/// Both re-check the board scope (§5.2 rule 3) first. The relay marks
/// `session_start` `begun` and echoes `received` before it gets here, and
/// owns its 24 h age (rules 1, 5, 6). Each handler owns its timeout and
/// never calls back into the relay processor.
@MainActor
final class SessionStartStopHandlers {
    /// The grants of the device a request came from (spec §4.13, §5.2 rule
    /// 4): the linked phone's row in the sidecar's `devices`
    /// (`MobileLinkCenter.sessionGrant`).
    struct DeviceGrant: Equatable, Sendable {
        let typingAllowed: Bool
        let startSessionsAllowed: Bool

        /// A newly linked phone's grants.
        static let specDefaults = Self(typingAllowed: false, startSessionsAllowed: true)
        /// No device, or its grants could not be read.
        static let denied = Self(typingAllowed: false, startSessionsAllowed: false)
    }

    typealias Grant = @MainActor (_ deviceID: String?) -> DeviceGrant
    typealias Pause = @MainActor (Duration) async -> Void

    /// Ample for the start's reads, writes and launch watch, or a close's
    /// grace.
    nonisolated static let defaultTimeout: Duration = .seconds(30)
    /// How long a new launch is watched for `exec claude` failing: a login
    /// shell that finds no `claude` exits at once.
    nonisolated static let defaultLaunchWatch: Duration = .seconds(3)
    nonisolated static let launchWatchStep: Duration = .milliseconds(100)
    static let timeoutMessage = "The Mac did not finish this in time — check the session on the Mac"
    static let kinds: [ActionKind] = [.sessionStart, .sessionStop]

    private let dbPool: DatabasePool
    private weak var workbenches: WorkbenchesViewModel?
    private let terminalCenter: TerminalCenter
    private let deviceGrant: Grant
    private let bringForward: @MainActor (Int64) -> Void
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let launchWatch: Duration
    private let launchPause: Pause

    init(
        dbPool: DatabasePool,
        workbenches: WorkbenchesViewModel?,
        terminalCenter: TerminalCenter,
        deviceGrant: @escaping Grant,
        bringForward: @escaping @MainActor (Int64) -> Void,
        timeout: Duration = SessionStartStopHandlers.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        launchWatch: Duration = SessionStartStopHandlers.defaultLaunchWatch,
        launchPause: @escaping Pause = { try? await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.workbenches = workbenches
        self.terminalCenter = terminalCenter
        self.deviceGrant = deviceGrant
        self.bringForward = bringForward
        self.timeout = timeout
        self.sleep = sleep
        self.launchWatch = launchWatch
        self.launchPause = launchPause
    }

    func register(on dispatcher: MobileHubCommandDispatcher) {
        for kind in Self.kinds {
            dispatcher.register(kind) { try await self.handle($0) }
        }
    }

    /// The echo of one action. A timeout is `outcome_unknown`: the start or
    /// close keeps running to its end and may still land.
    func handle(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        try await withHandlerTimeout(timeout, sleep: sleep, message: Self.timeoutMessage) {
            switch action.kind {
            case .sessionStart: try await self.start(action)
            case .sessionStop: try await self.stop(action)
            default: .failed(.unsupportedInPOC)
            }
        }
    }

    // MARK: - Start

    private func start(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard let targetID = action.entityID.flatMap(Int64.init),
              case let .integer(workbenchID)? = action.params["workbench_id"],
              case let .string(rawMode)? = action.params["mode"],
              case let .bool(planFirst)? = action.params["plan_first"],
              case let .bool(forward)? = action.params["bring_forward"] else {
            return .failed(.invalidParams, message: "session_start needs a target id, workbench_id, mode, plan_first and bring_forward")
        }
        let mode: WorkbenchesViewModel.TargetStartMode
        switch rawMode {
        case "new": mode = .new
        case "open_existing": mode = .openExisting
        default: return .failed(.invalidParams, message: "mode must be new or open_existing")
        }
        let brief: String?
        switch action.params["brief"] {
        case nil, .null?: brief = nil
        case let .string(text)?: brief = text
        default: return .failed(.invalidParams, message: "brief must be text")
        }
        let grant = deviceGrant(action.deviceID)
        guard grant.startSessionsAllowed else {
            return .failed(.deviceNotAllowed, message: "This phone is not allowed to start sessions on the Mac")
        }
        if let refusal = try await Self.scope(dbPool, targetID: targetID, workbenchID: workbenchID) { return refusal }
        guard let workbenches else { return .failed(.writeFailed, message: "The workbench is reloading on the Mac") }
        if forward { bringForward(workbenchID) }
        let liveBefore = terminalCenter.liveIDs
        let session: TerminalSession
        do {
            // An edited brief is honoured only from a device allowed to
            // type (spec §6.5); otherwise the work-on prompt goes.
            session = try await workbenches.startForTarget(
                targetID: targetID, prompt: grant.typingAllowed ? brief : nil, mode: mode,
                placement: forward ? .keeping(.board) : .background, planFirst: planFirst
            )
        } catch let error as WorkbenchesViewModel.TargetStartError {
            return Self.outcome(error)
        }
        // A session already running was not launched now: nothing to watch.
        if !liveBefore.contains(session.id), await exitedNotFound(session.id) {
            return .failed(.claudeNotFound, message: TerminalLaunch.exitMessage(code: 127))
        }
        return .applied(["session_id": .integer(session.id), "stage": .string("starting")])
    }

    /// True when the launch exited 127 within `launchWatch`. Any other exit
    /// is the session's own end: the start ran, and the phone sees the
    /// session stopped.
    private func exitedNotFound(_ sessionID: Int64) async -> Bool {
        var waited: Duration = .zero
        while waited < launchWatch, terminalCenter.states[sessionID] == .running {
            await launchPause(Self.launchWatchStep)
            waited += Self.launchWatchStep
        }
        return terminalCenter.states[sessionID] == .exited(127)
    }

    /// `.inProgress` refuses before anything is written; `.failed` covers a
    /// read or write error and a launch the terminal refused (or no
    /// terminal), never reported as started.
    private static func outcome(_ error: WorkbenchesViewModel.TargetStartError) -> ActionOutcome {
        switch error {
        case .notOnBoard: .failed(.notOnBoard, message: "That target is not on a workbench board")
        case .inProgress: .failed(.conflict, message: "A session for this target is being started on the Mac")
        case let .failed(message): .failed(.writeFailed, message: message)
        }
    }

    /// nil when the target is on `workbenchID`'s board (§5.2 rule 3).
    nonisolated private static func scope(_ dbPool: DatabasePool, targetID: Int64, workbenchID: Int64) async throws
        -> ActionOutcome? {
        try await dbPool.read { db in
            guard try WorkbenchQueries.fetch(db, id: workbenchID) != nil else {
                return .failed(.notFound, message: "This workbench no longer exists on the Mac")
            }
            guard let target = try TargetQueries.fetchByID(db, id: Int(targetID)) else {
                return .failed(.notFound, message: "This target no longer exists on the Mac")
            }
            guard target.workbenchID == workbenchID else {
                return .failed(.notOnBoard, message: "That target is not on this workbench's board")
            }
            return nil
        }
    }

    // MARK: - Stop

    private func stop(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard let sessionID = action.entityID.flatMap(Int64.init) else {
            return .failed(.invalidParams, message: "session_stop needs a session id")
        }
        // A board session only: the phone sees `claude` sessions of a
        // workbench and nothing else.
        let onBoard = try await dbPool.read { db -> Bool in
            guard let row = try TerminalSessionQueries.fetch(db, id: sessionID),
                  row.kind == .claude, let projectID = row.projectID else { return false }
            return try WorkbenchQueries.fetch(db, id: projectID) != nil
        }
        guard onBoard else { return .failed(.notFound, message: "This session no longer exists on the Mac") }
        if terminalCenter.liveIDs.contains(sessionID) {
            await terminalCenter.close(sessionID: sessionID)
        }
        return .applied()
    }
}
