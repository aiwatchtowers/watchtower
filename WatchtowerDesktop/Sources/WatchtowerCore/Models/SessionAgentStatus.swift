import Foundation
import GRDB

/// What a Claude Code session's workbench hooks last reported
/// (`terminal_sessions.agent_state`, migration 00098). Go is the only writer;
/// the Desktop reads it and never resets it.
package enum SessionAgentState: String, Sendable {
    case working, waiting, approval
}

/// One row of `TerminalSessionQueries.fetchAgentStates`: the stored state of
/// a session — the hook state, finished, the error, its open asks — and what
/// a notice about it names.
package struct SessionAgentStateRow: Decodable, FetchableRecord, Equatable, Sendable {
    package var id: Int64
    package var projectID: Int64?
    package var title: String
    /// The raw column; a value this build does not know reads as no state.
    package var agentState: String?
    /// UTC with milliseconds, `2026-10-03T12:34:56.789Z`.
    package var agentStateAt: String?
    /// nil for a standalone terminal or a workbench that no longer exists.
    package var workbenchName: String?
    /// Set by `finish_session` (same format as `agentStateAt`); nil = not
    /// finished. Any `working` write clears it.
    package var finishedAt: String?
    /// The last `finish_session` summary, kept after `finishedAt` clears.
    package var finishSummary: String
    /// The `agentStateAt` of the StopFailure write that set it; nil = no
    /// error.
    package var agentFailedAt: String?
    /// The StopFailure error type; '' when unknown.
    package var agentError: String
    /// The session's `owner_asks` with `status = 'open'`.
    package var openAsks: Int
    /// The oldest of those asks; nil when none is open.
    package var oldestOpenAskID: Int64?
    /// The background agents the last Stop or subagent report counted
    /// (migration 00106); nil = never reported.
    package var agentBackground: Int?
    /// When that count was reported (same format as `agentStateAt`).
    package var agentBackgroundAt: String?

    package init(
        id: Int64,
        projectID: Int64?,
        title: String,
        agentState: String?,
        agentStateAt: String?,
        workbenchName: String?,
        finishedAt: String? = nil,
        finishSummary: String = "",
        agentFailedAt: String? = nil,
        agentError: String = "",
        openAsks: Int = 0,
        oldestOpenAskID: Int64? = nil,
        agentBackground: Int? = nil,
        agentBackgroundAt: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.agentState = agentState
        self.agentStateAt = agentStateAt
        self.workbenchName = workbenchName
        self.finishedAt = finishedAt
        self.finishSummary = finishSummary
        self.agentFailedAt = agentFailedAt
        self.agentError = agentError
        self.openAsks = openAsks
        self.oldestOpenAskID = oldestOpenAskID
        self.agentBackground = agentBackground
        self.agentBackgroundAt = agentBackgroundAt
    }

    package var stored: SessionAgentState? { agentState.flatMap(SessionAgentState.init(rawValue:)) }

    package enum CodingKeys: String, CodingKey {
        case id, title
        case projectID = "project_id"
        case agentState = "agent_state"
        case agentStateAt = "agent_state_at"
        case workbenchName = "workbench_name"
        case finishedAt = "finished_at"
        case finishSummary = "finish_summary"
        case agentFailedAt = "agent_failed_at"
        case agentError = "agent_error"
        case openAsks = "open_asks"
        case oldestOpenAskID = "oldest_open_ask_id"
        case agentBackground = "agent_background"
        case agentBackgroundAt = "agent_background_at"
    }
}

/// A session's effective status — what the dots, captions and notices show
/// (spec 2026-10-03-session-agent-state, decisions 9–12; the state set of
/// spec 2026-10-03-workbench-session-report §4b).
package struct SessionAgentStatus: Equatable, Sendable {
    package let sessionID: Int64
    package let workbenchID: Int64?
    package let workbenchName: String?
    package let title: String
    package let state: SessionSwitcherPresentation.State
    /// The trusted hook state's `agent_state_at`; nil when no hook state is
    /// trusted (not live, or none written during this run).
    package let at: String?
    /// The row holds the current run's mark and no state: a stamp of this
    /// run that the SessionStart hook writes only for a folder with the
    /// session state hooks (Go `MarkTerminalAgentRun`, board #396) — the
    /// hooks run, and the agent has not started a turn.
    package let runMarked: Bool
    /// The last `finish_session` summary ('' when none), a finished
    /// notice's body.
    package let finishSummary: String

    package init(
        sessionID: Int64,
        workbenchID: Int64?,
        workbenchName: String?,
        title: String,
        state: SessionSwitcherPresentation.State,
        at: String?,
        runMarked: Bool = false,
        finishSummary: String = ""
    ) {
        self.sessionID = sessionID
        self.workbenchID = workbenchID
        self.workbenchName = workbenchName
        self.title = title
        self.state = state
        self.at = at
        self.runMarked = runMarked
        self.finishSummary = finishSummary
    }

    /// The §4b order over a row: the hook states count only for a live
    /// session and only when written during the current process run
    /// (`agent_state_at ≥ startedAt`, decision 9) — a state from an earlier
    /// run, an unknown start time or an unreadable stamp counts as none,
    /// never a dead run's state. `finished` and the open asks are not
    /// run-scoped, so they show whether the session runs or not. No
    /// staleness timeout on a hook state: a turn may work for an hour; the
    /// background count's end is `policy`'s alone, read at `now` (#411),
    /// unless `displayOver` — two failed staleness probes in a row for this
    /// count (spec 2026-10-10-session-background-agents §10): then the count
    /// reads as over, with no write.
    package static func effective(
        row: SessionAgentStateRow,
        live: Bool,
        startedAt: Date?,
        now: Date,
        policy: SessionBackgroundPolicy = .current,
        displayOver: Bool = false
    ) -> SessionSwitcherPresentation.State {
        let hook = live ? trustedHook(row, startedAt: startedAt) : nil
        let failed = hook == .waiting && row.agentFailedAt != nil && row.agentFailedAt == row.agentStateAt
        let agents = hook == .waiting && !failed && !displayOver
            ? backgroundAgents(row, now: now, policy: policy) : nil
        let kind: SessionSwitcherPresentation.State.Kind
        if hook == .approval {
            kind = .needsApproval
        } else if failed {
            kind = .failed
        } else if hook == .working {
            kind = .working
        } else if agents != nil {
            kind = .background
        } else if row.finishedAt != nil {
            kind = .finished
        } else if row.openAsks > 0 {
            kind = .waitingOnAsk
        } else if hook == .waiting {
            kind = .stopped
        } else {
            kind = live ? .running : .notStarted
        }
        return SessionSwitcherPresentation.State(
            kind: kind, live: live, openAsks: row.openAsks, error: failed ? row.agentError : "",
            oldestAskID: row.openAsks > 0 ? row.oldestOpenAskID : nil, backgroundAgents: agents ?? 0
        )
    }

    /// The row's background agent count while `policy` says they run; nil
    /// without a count, with an unreadable report stamp, or once over.
    private static func backgroundAgents(
        _ row: SessionAgentStateRow, now: Date, policy: SessionBackgroundPolicy
    ) -> Int? {
        guard let count = row.agentBackground,
              let reported = row.agentBackgroundAt.flatMap(parseStamp),
              policy.verdict(count: count, lastReport: reported, now: now) == .running else { return nil }
        return count
    }

    /// The row's hook state when it was written during the run started at
    /// `startedAt`; nil otherwise.
    private static func trustedHook(_ row: SessionAgentStateRow, startedAt: Date?) -> SessionAgentState? {
        guard let stored = row.stored, writtenThisRun(row, startedAt: startedAt) else { return nil }
        return stored
    }

    /// Whether the row's `agent_state_at` was written during the run
    /// started at `startedAt` (an unknown start or an unreadable stamp: no).
    private static func writtenThisRun(_ row: SessionAgentStateRow, startedAt: Date?) -> Bool {
        guard let startedAt, let at = row.agentStateAt.flatMap(parseStamp) else { return false }
        return at >= startedAt
    }

    /// The agent's turn is over and it sits at its prompt: a trusted
    /// `waiting` of the current run (stopped, failed, background agents
    /// running, or finished/waiting on an ask over a turn end) — where a
    /// hand-off may press Return.
    package var isAtPrompt: Bool {
        guard state.live, at != nil else { return false }
        switch state.kind {
        case .stopped, .failed, .finished, .waitingOnAsk, .background: return true
        case .notStarted, .running, .working, .needsApproval: return false
        }
    }

    /// The session's hooks wrote during its current run — a hook state or
    /// the run's mark — so a permission prompt on screen would show as
    /// `needsApproval`: an ask's answer may get its Return (PROJ-12).
    package var hooksReported: Bool { at != nil || runMarked }

    /// Whether this status still holds for a run started at `startedAt`:
    /// one without a trusted hook state always does, one with it only when
    /// that state was written during that run (decision 9 again, for a run that began after the read).
    /// A status holding only the run's mark carries no `at` (the row's mark
    /// has its `agent_state_at`, which only `resolve` checks), so it holds
    /// for no run here: only a fresh `resolve` vouches for it.
    package func isTrusted(startedAt: Date?) -> Bool {
        guard let at else { return !runMarked }
        guard let startedAt, let stamp = Self.parseStamp(at) else { return false }
        return stamp >= startedAt
    }

    /// The statuses of `rows`, keyed by session id; liveness comes from
    /// `liveIDs`, the background count is judged at `now`, and reads as over
    /// for the sessions in `displayOver`.
    package static func resolve(
        _ rows: [SessionAgentStateRow],
        liveIDs: Set<Int64>,
        startedAt: [Int64: Date],
        now: Date,
        policy: SessionBackgroundPolicy = .current,
        displayOver: Set<Int64> = []
    ) -> [Int64: Self] {
        var result: [Int64: Self] = [:]
        for row in rows {
            let live = liveIDs.contains(row.id)
            let trusted = live && trustedHook(row, startedAt: startedAt[row.id]) != nil
            // The run's mark: no state at all — a value this build does not
            // know may be a dialog of its own, so it vouches for nothing.
            let marked = live && row.agentState == nil && writtenThisRun(row, startedAt: startedAt[row.id])
            result[row.id] = Self(
                sessionID: row.id,
                workbenchID: row.projectID,
                workbenchName: row.workbenchName,
                title: row.title,
                state: effective(row: row, live: live, startedAt: startedAt[row.id], now: now, policy: policy,
                                 displayOver: displayOver.contains(row.id)),
                at: trusted ? row.agentStateAt : nil,
                runMarked: marked,
                finishSummary: row.finishSummary
            )
        }
        return result
    }

    // Go writes the column in UTC; the parser pins UTC too (dual-path
    // datetime rule), whatever the process time zone.
    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Parses an `agent_state_at` stamp; nil for anything else.
    package static func parseStamp(_ stamp: String) -> Date? {
        stampFormatter.date(from: stamp)
    }
}
