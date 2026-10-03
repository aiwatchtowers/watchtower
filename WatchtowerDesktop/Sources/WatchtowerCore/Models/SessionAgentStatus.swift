import Foundation
import GRDB

/// What a Claude Code session's workbench hooks last reported
/// (`terminal_sessions.agent_state`, migration 00098). Go is the only writer;
/// the Desktop reads it and never resets it.
package enum SessionAgentState: String, Sendable {
    case working, waiting, approval
}

/// One row of `TerminalSessionQueries.fetchAgentStates`: the stored state of
/// a session and what a notice about it names.
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

    package init(
        id: Int64,
        projectID: Int64?,
        title: String,
        agentState: String?,
        agentStateAt: String?,
        workbenchName: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.agentState = agentState
        self.agentStateAt = agentStateAt
        self.workbenchName = workbenchName
    }

    package var stored: SessionAgentState? { agentState.flatMap(SessionAgentState.init(rawValue:)) }

    package enum CodingKeys: String, CodingKey {
        case id, title
        case projectID = "project_id"
        case agentState = "agent_state"
        case agentStateAt = "agent_state_at"
        case workbenchName = "workbench_name"
    }
}

/// A live session's effective status — what the dots, captions and notices
/// show (spec 2026-10-03-session-agent-state, decisions 9–12).
package struct SessionAgentStatus: Equatable, Sendable {
    package let sessionID: Int64
    package let workbenchID: Int64?
    package let workbenchName: String?
    package let title: String
    package let state: SessionSwitcherPresentation.State
    /// The trusted state's `agent_state_at`; nil when no stored state is
    /// trusted (plain running).
    package let at: String?

    package init(
        sessionID: Int64,
        workbenchID: Int64?,
        workbenchName: String?,
        title: String,
        state: SessionSwitcherPresentation.State,
        at: String?
    ) {
        self.sessionID = sessionID
        self.workbenchID = workbenchID
        self.workbenchName = workbenchName
        self.title = title
        self.state = state
        self.at = at
    }

    /// The trust rule (decision 9): a stored state counts only for a live
    /// session and only when it was written during the current process run
    /// (`storedAt ≥ startedAt`). A state from an earlier run, an unknown
    /// start time or an unreadable stamp shows plain running — never a dead
    /// run's "waiting". No staleness timeout: a turn may work for an hour.
    package static func effective(
        live: Bool,
        stored: SessionAgentState?,
        storedAt: String?,
        startedAt: Date?
    ) -> SessionSwitcherPresentation.State {
        guard live else { return .notStarted }
        guard let stored, let startedAt, let at = storedAt.flatMap(parseStamp), at >= startedAt else {
            return .running
        }
        switch stored {
        case .working: return .working
        case .waiting: return .waitingForOwner
        case .approval: return .needsApproval
        }
    }

    /// The statuses of the live sessions among `rows`, keyed by session id.
    /// A row that is not live is left out.
    package static func resolve(
        _ rows: [SessionAgentStateRow],
        liveIDs: Set<Int64>,
        startedAt: [Int64: Date]
    ) -> [Int64: Self] {
        var result: [Int64: Self] = [:]
        for row in rows where liveIDs.contains(row.id) {
            let state = effective(
                live: true, stored: row.stored, storedAt: row.agentStateAt, startedAt: startedAt[row.id]
            )
            result[row.id] = Self(
                sessionID: row.id,
                workbenchID: row.projectID,
                workbenchName: row.workbenchName,
                title: row.title,
                state: state,
                at: state == .running ? nil : row.agentStateAt
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
