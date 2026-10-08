import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// What the projection needs of the Mac's terminals: the sessions whose
/// process runs and when each run started (`TerminalCenter.liveIDs` and
/// `startedAt`, main-actor state). The fast lane copies it here, so the
/// slice can resolve states inside the publisher's off-main DB read.
struct SessionLiveness: Equatable, Sendable {
    var liveIDs: Set<Int64> = []
    var startedAt: [Int64: Date] = [:]
}

/// The lock-guarded `SessionLiveness` the fast lane writes and the slice
/// reads.
final class SessionLivenessBox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: SessionLiveness())

    var current: SessionLiveness { state.withLock { $0 } }

    /// Stores `next`; whether it differed from the stored value.
    @discardableResult
    func update(_ next: SessionLiveness) -> Bool {
        state.withLock { current in
            guard current != next else { return false }
            current = next
            return true
        }
    }
}

/// The `terminal_session` slice (mobile POC spec §4.5), record name
/// `terminal_session-<terminal_sessions.id>`: the `claude` sessions of the
/// published workbenches — every live one plus the newest 50 by
/// `last_active_at` per workbench. Shell sessions are not published.
///
/// The state fields are the Mac's resolved presentation, computed the way
/// the Mac computes it: the stored rows of `fetchAgentStates` through
/// `SessionAgentStatus.resolve` (the center's resolution) and
/// `SessionSwitcherPresentation.state(of:)` (the switcher's), then rendered
/// by `SessionStatePresentation`. The caption carries no age, so a record
/// does not change every minute. `claude_session_id`, `folder_path` and the
/// raw hook columns are never published (only the Payload is encoded).
///
/// Wire shape: the Kit mirror `WatchtowerKit.TerminalSessionState`.
struct TerminalSessionSlice: SliceSource {
    let kind = SliceKind.terminalSession

    static let newestPerWorkbench = 50

    let liveness: @Sendable () -> SessionLiveness
    /// The report summary runner's last good summary of a session
    /// (workbench id, session id); nil before its first run.
    let reportSummary: @Sendable (Int64, Int64) -> SessionReportSummary?

    init(
        liveness: @escaping @Sendable () -> SessionLiveness,
        reportSummary: @escaping @Sendable (Int64, Int64) -> SessionReportSummary?
    ) {
        self.liveness = liveness
        self.reportSummary = reportSummary
    }

    struct Payload: Encodable, Equatable {
        let id: Int64
        let workbenchID: Int64
        let title: String
        let titleClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let targetID: Int64?
        let agent: String
        let createdAt: Date
        let lastActiveAt: Date
        let stateAt: Date?
        let live: Bool
        let stateKind: String
        let stateCaption: String
        let stateCaptionClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let stateTone: String
        let stateGlyph: String
        let isRing: Bool
        let openAsks: Int
        let oldestAskID: Int64?
        let closedAsks: Int
        let finishSummary: String
        let finishSummaryClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let agentError: String
        let agentErrorClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let reportTargetID: Int64?
        let reportDone: Int?
        let reportTotal: Int?
        let reportPRLine: String?
        let reportPRLineClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean

        enum CodingKeys: String, CodingKey {
            case id
            case workbenchID = "workbench_id"
            case title, titleClipped
            case targetID = "target_id"
            case agent, createdAt, lastActiveAt, stateAt, live, stateKind, stateCaption, stateCaptionClipped
            case stateTone, stateGlyph, isRing, openAsks
            case oldestAskID = "oldest_ask_id"
            case closedAsks, finishSummary, finishSummaryClipped, agentError, agentErrorClipped
            case reportTargetID = "report_target_id"
            case reportDone, reportTotal
            case reportPRLine = "report_pr_line"
            case reportPRLineClipped = "report_pr_line_clipped"
        }
    }

    /// One published session with its resolved state.
    struct Published {
        let session: TerminalSession
        let workbenchID: Int64
        let state: SessionSwitcherPresentation.State
        let status: SessionAgentStatus?
        let row: SessionAgentStateRow?
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let published = try publishedSessions(db)
        guard !published.isEmpty else { return [] }
        var closed: [Int64: [Int64?: Int]] = [:]
        for workbenchID in Set(published.map(\.workbenchID)) {
            closed[workbenchID] = try OwnerAskQueries.closedCounts(db, projectID: workbenchID)
        }
        let encoder = RelayCoder.makeEncoder()
        return try published.map { item in
            let payload = makePayload(item, closedAsks: closed[item.workbenchID]?[item.session.id] ?? 0)
            let modified = SliceDate.parse(item.session.lastActiveAt) ?? Date(timeIntervalSince1970: 0)
            return SliceRecord(kind: kind, id: String(item.session.id), modifiedAt: modified, payload: try encoder.encode(payload))
        }
    }

    /// `session_counts` of the `workbench` slice, over the same published
    /// sessions and states. `working` counts working and running (both
    /// green), `not_running` counts not started.
    func sessionCounts(_ db: Database) throws -> [Int64: WorkbenchSlice.Payload.SessionCounts] {
        var counts: [Int64: WorkbenchSlice.Payload.SessionCounts] = [:]
        for item in try publishedSessions(db) {
            var entry = counts[item.workbenchID] ?? .init()
            switch item.state.kind {
            case .working, .running: entry.working += 1
            case .waitingOnAsk: entry.waiting += 1
            case .needsApproval: entry.needsApproval += 1
            case .finished: entry.finished += 1
            case .failed: entry.failed += 1
            case .stopped: entry.stopped += 1
            case .notStarted: entry.notRunning += 1
            }
            counts[item.workbenchID] = entry
        }
        return counts
    }

    /// The window: the published workbenches' `claude` sessions, every live
    /// one plus the newest 50 per workbench, in `last_active_at` order.
    func publishedSessions(_ db: Database) throws -> [Published] {
        let workbenches = Set(try WorkbenchSlice.publishedWorkbenches(db).map(\.id))
        guard !workbenches.isEmpty else { return [] }
        let live = liveness()
        let sessions = try TerminalSessionQueries.fetchAllWorkbenchSessions(db).filter { session in
            session.kind == .claude && session.projectID.map(workbenches.contains) == true
        }
        let windowed = Self.window(sessions, liveIDs: live.liveIDs)
        guard !windowed.isEmpty else { return [] }
        // Only workbench `claude` rows: no standalone live ids are passed.
        let rows = try TerminalSessionQueries.fetchAgentStates(db, liveIDs: [])
        let statuses = SessionAgentStatus.resolve(rows, liveIDs: live.liveIDs, startedAt: live.startedAt)
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        return windowed.compactMap { session in
            guard let workbenchID = session.projectID else { return nil }
            return Published(
                session: session,
                workbenchID: workbenchID,
                state: SessionSwitcherPresentation.state(of: session.id, liveIDs: live.liveIDs, statuses: statuses),
                status: statuses[session.id],
                row: rowsByID[session.id]
            )
        }
    }

    /// Per workbench, the first `newestPerWorkbench` of `sessions` (already
    /// newest first) plus every live one past them; the order is kept.
    static func window(_ sessions: [TerminalSession], liveIDs: Set<Int64>) -> [TerminalSession] {
        var seen: [Int64: Int] = [:]
        return sessions.filter { session in
            let workbench = session.projectID ?? 0
            let rank = seen[workbench, default: 0]
            seen[workbench] = rank + 1
            return rank < newestPerWorkbench || liveIDs.contains(session.id)
        }
    }

    /// The workbenches with a live `claude` session (the report summary
    /// runner's 60 s cadence).
    static func liveWorkbenchIDs(_ db: Database, liveIDs: Set<Int64>) throws -> [Int64] {
        guard !liveIDs.isEmpty else { return [] }
        let ids = Array(liveIDs)
        return try Int64.fetchAll(
            db,
            sql: """
                SELECT DISTINCT project_id FROM terminal_sessions
                WHERE kind = 'claude' AND project_id IS NOT NULL AND id IN (\(databaseQuestionMarks(count: ids.count)))
                ORDER BY project_id
                """,
            arguments: StatementArguments(ids)
        )
    }

    private func makePayload(_ item: Published, closedAsks: Int) -> Payload {
        let session = item.session
        let state = item.state
        let record = kind.recordName(id: String(session.id))
        let title = SliceClip.text(session.title, limit: 200)
        let caption = SliceClip.text(SessionStatePresentation.caption(for: state), limit: 120)
        let finish = SliceClip.text(item.row?.finishSummary ?? "", limit: 2000)
        let error = SliceClip.text(state.error, limit: 60)
        let summary = reportSummary(item.workbenchID, session.id)
        let prLine = summary.map { SliceClip.text($0.prLine, limit: 120) }
        return Payload(
            id: session.id,
            workbenchID: item.workbenchID,
            title: title.text, titleClipped: title.clipped,
            targetID: session.targetID,
            agent: "claude_code",
            createdAt: SliceDate.required(session.createdAt, field: "created_at", record: record),
            lastActiveAt: SliceDate.required(session.lastActiveAt, field: "last_active_at", record: record),
            stateAt: Self.stateAt(item),
            live: state.live,
            stateKind: Self.wire(state.kind),
            stateCaption: caption.text, stateCaptionClipped: caption.clipped,
            stateTone: Self.wire(SessionStatePresentation.color(for: state)),
            stateGlyph: SessionStatePresentation.glyph(for: state) ?? "",
            isRing: SessionStatePresentation.isRing(state),
            openAsks: state.openAsks,
            oldestAskID: state.oldestAskID,
            closedAsks: closedAsks,
            finishSummary: finish.text, finishSummaryClipped: finish.clipped,
            agentError: error.text, agentErrorClipped: error.clipped,
            reportTargetID: summary?.targetID,
            reportDone: summary?.done,
            reportTotal: summary?.total,
            reportPRLine: prLine?.text,
            reportPRLineClipped: prLine?.clipped
        )
    }

    /// When the current state was reported: the trusted hook stamp, else a
    /// finished session's `finished_at`; nil when unknown.
    static func stateAt(_ item: Published) -> Date? {
        if let at = item.status?.at { return SliceDate.parse(at) }
        if item.state.kind == .finished, let finished = item.row?.finishedAt { return SliceDate.parse(finished) }
        return nil
    }

    /// The Kit's `TerminalSessionState.Kind` raw values.
    static func wire(_ kind: SessionSwitcherPresentation.State.Kind) -> String {
        switch kind {
        case .working: "working"
        case .running: "running"
        case .waitingOnAsk: "waiting_on_ask"
        case .needsApproval: "needs_approval"
        case .finished: "finished"
        case .stopped: "stopped"
        case .failed: "failed"
        case .notStarted: "not_started"
        }
    }

    /// The Kit's `TerminalSessionState.Tone` raw values.
    static func wire(_ tone: SessionStatePresentation.Tone) -> String {
        switch tone {
        case .green: "green"
        case .orange: "orange"
        case .blue: "blue"
        case .red: "red"
        case .secondary: "secondary"
        }
    }
}
