import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// The Mac-side gates for acting on a running session: typing a line into
/// it (PROJ-16), one Esc (PROJ-21 §6) and answering its permission prompt
/// (PROJ-21). Shared by the phone's handlers (`SessionInputHandlers`,
/// `PermissionAnswerHandlers`), which keep their device grants, board scope
/// and action age on top, and the Workchat composer (#711), whose answers
/// are decided by `"Mac"`.
@MainActor
final class SessionControl {
    typealias Status = @MainActor (_ sessionID: Int64) -> SessionAgentStatus?

    /// After the app submits a line to a session, the session counts as
    /// busy until a state read shows a hook stamp newer than the submit (its
    /// UserPromptSubmit hook lands asynchronously), or this long passed.
    static let submitSettle: TimeInterval = 30

    private let dbPool: DatabasePool
    private let terminalCenter: TerminalCenter
    private let lineDelivery: SessionLineDelivery
    private let status: Status
    private let now: () -> Date

    init(
        dbPool: DatabasePool,
        terminalCenter: TerminalCenter,
        lineDelivery: SessionLineDelivery,
        status: @escaping Status,
        now: @escaping () -> Date = Date.init
    ) {
        self.dbPool = dbPool
        self.terminalCenter = terminalCenter
        self.lineDelivery = lineDelivery
        self.status = status
        self.now = now
    }

    // MARK: - Line

    enum LineHold: Equatable { case needsApproval, agentBusy, promptHasText }
    enum LineCheck: Equatable { case go, hold(LineHold), sessionGone }

    /// PROJ-16's session conditions right before a paste, read after a
    /// fresh state read: a session the states do not list was deleted; then
    /// a permission prompt, a busy agent (or one turning to a line just
    /// submitted), the owner's text in the prompt.
    func lineCheck(_ sessionID: Int64) -> LineCheck {
        guard let current = status(sessionID) else { return .sessionGone }
        if current.state.kind == .needsApproval { return .hold(.needsApproval) }
        guard Self.isIdle(current), !justSubmitted(sessionID, status: current) else { return .hold(.agentBusy) }
        if terminalCenter.promptHoldsText(sessionID) { return .hold(.promptHasText) }
        return .go
    }

    /// The Workchat's check (#711): `lineCheck`, except that an agent that
    /// works (Working, Agents working) does not hold the line, since Claude
    /// Code queues a line typed mid-turn and reads it at its next step, as
    /// in the terminal. A session not live, a run with no hook state yet, a
    /// permission prompt, a line just submitted and text in the prompt
    /// still hold it. The phone keeps `lineCheck` (PROJ-16).
    func workchatLineCheck(_ sessionID: Int64) -> LineCheck {
        guard let current = status(sessionID) else { return .sessionGone }
        if current.state.kind == .needsApproval { return .hold(.needsApproval) }
        guard Self.isIdle(current) || Self.isWorking(current) else { return .hold(.agentBusy) }
        if justSubmitted(sessionID, status: current) { return .hold(.agentBusy) }
        if terminalCenter.promptHoldsText(sessionID) { return .hold(.promptHasText) }
        return .go
    }

    /// Whether the session's agent works now (a turn or background agents).
    func isWorking(_ sessionID: Int64) -> Bool {
        status(sessionID).map(Self.isWorking) ?? false
    }

    /// A line went into the session within `submitSettle` and no hook has
    /// reported since: the agent is turning to it (its Working may not be
    /// written yet).
    private func justSubmitted(_ sessionID: Int64, status: SessionAgentStatus) -> Bool {
        guard let submitted = lineDelivery.submittedAt(sessionID),
              now().timeIntervalSince(submitted) < Self.submitSettle else { return false }
        guard let stamp = status.at.flatMap(SessionAgentStatus.parseStamp) else { return true }
        return stamp <= submitted
    }

    /// The agent is idle for the current run: its turn ended — Stopped,
    /// Finished, Waiting for you (or Ready to check, its #534 form when the
    /// open asks are all checks or reviews) or Error by a hook state of this
    /// run — or the run is marked and no turn began (spec §6.6).
    static func isIdle(_ status: SessionAgentStatus) -> Bool {
        guard status.state.live else { return false }
        guard status.at != nil else { return status.runMarked }
        switch status.state.kind {
        case .stopped, .finished, .waitingOnAsk, .readyToCheck, .failed: return true
        case .notStarted, .running, .working, .background, .needsApproval: return false
        }
    }

    // MARK: - Interrupt

    enum InterruptResult: Equatable { case sent, notRunning, notWorking, awaitingApproval }

    /// One Esc, only into a running session whose agent works and that
    /// shows no permission prompt.
    func interrupt(_ sessionID: Int64) async throws -> InterruptResult {
        guard terminalCenter.liveIDs.contains(sessionID) else { return .notRunning }
        guard let current = status(sessionID), Self.isWorking(current) else { return .notWorking }
        // Claude Code draws a prompt before its hook reports it, so the
        // state above may still say Working: a pending request means a
        // prompt is on screen, and an Esc would reject it (spec §6).
        guard try await !hasPendingRequest(sessionID) else { return .awaitingApproval }
        guard terminalCenter.sendInterrupt(sessionID: sessionID) else { return .notRunning }
        return .sent
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

    // MARK: - Permission

    struct PermissionPrompt: Equatable, Identifiable {
        let id: Int64
        let toolName: String
        let summary: String
        /// Why only a deny may answer it here; nil when an allow may.
        let allowBlock: PermissionAllowBlock?
    }

    /// The session's newest pending permission request; nil when none.
    func pendingPermission(_ sessionID: Int64) async throws -> PermissionPrompt? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, tool_name, summary, summary_clipped FROM permission_requests
                    WHERE terminal_session_id = ? AND status = 'pending'
                    ORDER BY id DESC LIMIT 1
                    """,
                arguments: [sessionID]
            ) else { return nil }
            let toolName: String = row["tool_name"]
            let summary: String = row["summary"]
            return PermissionPrompt(
                id: row["id"], toolName: toolName, summary: summary,
                allowBlock: Self.allowBlock(toolName: toolName, summary: summary, clippedByGo: row["summary_clipped"])
            )
        }
    }

    enum PermissionAnswer: Equatable {
        /// Decided: the status written (`allowed` or `denied`).
        case applied(String)
        case notFound
        /// Not pending (any more): its status, `""` when the row is gone.
        case notPending(String)
        case allowBlocked(PermissionAllowBlock)
        case notRunning
    }

    /// Decides one request of `sessionID`. Order: the row exists (else
    /// `notFound`) and is pending (else `notPending`) → an allow that may
    /// be given (`PermissionAllowBlock`; a deny always may) → the session
    /// runs → one guarded `UPDATE … WHERE status = 'pending'`, so an answer
    /// that got there first leaves this one `notPending`. Only the hook's
    /// JSON decides the prompt: nothing is typed into the terminal.
    func answerPermission(requestID: Int64, sessionID: Int64, allow: Bool, decidedBy: String) async throws -> PermissionAnswer {
        guard let current = try await storedRequest(requestID, sessionID: sessionID) else { return .notFound }
        guard current.status == "pending" else { return .notPending(current.status) }
        if allow, let block = current.allowBlock { return .allowBlocked(block) }
        guard terminalCenter.liveIDs.contains(sessionID) else { return .notRunning }
        let decided = allow ? "allowed" : "denied"
        let stamp = SessionAgentStatus.formatStamp(now())
        // One short write: the guard keeps an answer that landed since the read.
        let changed = try await dbPool.write { db -> Int in
            try db.execute(
                sql: """
                    UPDATE permission_requests SET status = ?, decided_at = ?, decided_by = ?
                    WHERE id = ? AND terminal_session_id = ? AND status = 'pending'
                    """,
                arguments: [decided, stamp, decidedBy, requestID, sessionID]
            )
            return db.changesCount
        }
        guard changed == 1 else {
            let after = try await storedRequest(requestID, sessionID: sessionID)
            return .notPending(after?.status ?? "")
        }
        return .applied(decided)
    }

    /// What an answer needs of a stored request.
    private struct StoredRequest {
        let status: String
        /// Why only a deny may answer it; nil when an allow may.
        let allowBlock: PermissionAllowBlock?
    }

    /// The row when it is `sessionID`'s request; nil otherwise.
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
            return StoredRequest(
                status: row["status"],
                allowBlock: Self.allowBlock(toolName: row["tool_name"], summary: row["summary"], clippedByGo: row["summary_clipped"])
            )
        }
    }

    /// The allow rule as the phone sees the request — shortened by Go's
    /// flag or the slice's own cap — plus the Mac's symlink-resolved path.
    nonisolated private static func allowBlock(toolName: String, summary: String, clippedByGo: Bool) -> PermissionAllowBlock? {
        let clipped = PermissionRequestSlice.wireSummary(summary, clippedByGo: clippedByGo).clipped
        return PermissionAllowBlock.check(toolName: toolName, summary: summary, clipped: clipped)
            ?? resolvedSettingsPath(toolName: toolName, path: summary)
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
}
