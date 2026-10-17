import Foundation

/// What `watchtower agents report --json` prints (#298). Mirrors the Go
/// structs in `internal/agentreport` (pinned by `TestAgentsReportJSON_PinnedKeys`);
/// durations are milliseconds.

/// Where a stretch of an agent's time went (`Segment.category`).
package enum AgentTimeCategory: String, Sendable {
    case model, tool, background, owner, away
}

package struct AgentToolTimes: Decodable, Equatable, Sendable {
    package let buildTest: Int64
    package let git: Int64
    package let readSearch: Int64
    package let edit: Int64
    package let mcp: Int64
    package let subagentsFG: Int64
    package let other: Int64

    enum CodingKeys: String, CodingKey {
        case buildTest = "build_test", git
        case readSearch = "read_search", edit, mcp
        case subagentsFG = "subagents_fg", other
    }
}

package struct AgentTimeSplit: Decodable, Equatable, Sendable {
    package let modelMS: Int64
    package let tools: AgentToolTimes
    package let backgroundMS: Int64
    package let ownerMS: Int64
    package let awayMS: Int64
    package let activeMS: Int64
    package let wallMS: Int64

    enum CodingKeys: String, CodingKey {
        case modelMS = "model_ms", tools
        case backgroundMS = "background_ms", ownerMS = "owner_ms"
        case awayMS = "away_ms", activeMS = "active_ms", wallMS = "wall_ms"
    }
}

package struct AgentSubagents: Decodable, Equatable, Sendable {
    package let count: Int
    package let foreground: Int
    package let background: Int
    package let peak: Int
    package let serial: Int
    package let busyMS: Int64
    package let unionMS: Int64
    package let blockedMS: Int64
    package let avgParallel: Double

    enum CodingKeys: String, CodingKey {
        case count, foreground, background, peak, serial
        case busyMS = "busy_ms", unionMS = "union_ms", blockedMS = "blocked_ms"
        case avgParallel = "avg_parallel"
    }
}

package struct AgentTokens: Decodable, Equatable, Sendable {
    package let input: Int64
    package let output: Int64
    package let cacheRead: Int64
    package let cacheWrite5m: Int64
    package let cacheWrite1h: Int64

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read", cacheWrite5m = "cache_write_5m", cacheWrite1h = "cache_write_1h"
    }
}

package struct AgentReportTotals: Decodable, Equatable, Sendable {
    package let sessions: Int
    package let activeMS: Int64
    package let awayMS: Int64
    package let costUSD: Double
    package let costEstimatedCalls: Int
    package let tokens: AgentTokens

    enum CodingKeys: String, CodingKey {
        case sessions, tokens
        case activeMS = "active_ms", awayMS = "away_ms", costUSD = "cost_usd"
        case costEstimatedCalls = "cost_estimated_calls"
    }
}

package struct AgentCommandRow: Decodable, Equatable, Sendable {
    package let verb: String
    package let `class`: String
    package let runs: Int
    package let errors: Int
    package let totalMS: Int64
    package let avgMS: Int64

    enum CodingKeys: String, CodingKey {
        case verb, `class`, runs, errors
        case totalMS = "total_ms", avgMS = "avg_ms"
    }
}

package struct AgentModelRow: Decodable, Equatable, Sendable {
    package let model: String
    package let mainCostUSD: Double
    package let subCostUSD: Double
    package let tokens: Int64
    package let cacheReadShare: Double

    enum CodingKeys: String, CodingKey {
        case model, tokens
        case mainCostUSD = "main_cost_usd", subCostUSD = "sub_cost_usd"
        case cacheReadShare = "cache_read_share"
    }
}

package struct AgentHintEvidence: Decodable, Equatable, Sendable {
    /// `command`, `target` or `session`.
    package let kind: String
    package let ref: String
    package let label: String
}

package struct AgentHint: Decodable, Equatable, Sendable {
    /// `H1`…`H7`.
    package let id: String
    package let finding: String
    package let estimateMS: Int64
    package let estimateUSD: Double
    package let evidence: [AgentHintEvidence]

    enum CodingKeys: String, CodingKey {
        case id, finding, evidence
        case estimateMS = "estimate_ms", estimateUSD = "estimate_usd"
    }
}

package struct AgentTaskRow: Decodable, Equatable, Sendable {
    package let targetID: Int64
    package let text: String
    package let status: String
    package let calendarMS: Int64
    /// `in_progress`, `in_review`, `blocked`, `todo`.
    package let phases: [String: Int64]
    package let agentMS: Int64
    package let time: AgentTimeSplit
    package let costUSD: Double
    package let sessions: [String]
    package let shared: Bool

    enum CodingKeys: String, CodingKey {
        case text, status, phases, time, sessions, shared
        case targetID = "target_id", calendarMS = "calendar_ms"
        case agentMS = "agent_ms", costUSD = "cost_usd"
    }
}

/// One session's line in the overview; an old-format session has no time fields.
package struct AgentSessionRow: Decodable, Equatable, Sendable {
    package let uuid: String
    package let startedAt: String
    package let endedAt: String
    package let model: String
    package let branch: String
    package let activeMS: Int64
    package let costUSD: Double
    package let avgParallel: Double
    package let oldFormat: Bool
    package let prs: [String]

    enum CodingKeys: String, CodingKey {
        case model, branch, prs
        case uuid = "session_uuid", startedAt = "started_at", endedAt = "ended_at"
        case activeMS = "active_ms", costUSD = "cost_usd", avgParallel = "avg_parallel"
        case oldFormat = "old_format"
    }
}

package struct AgentSegment: Decodable, Equatable, Sendable {
    package let start: String
    package let end: String
    /// An `AgentTimeCategory` raw value; kept a string so a newer CLI never fails the decode.
    package let category: String
    package let toolClass: String
    package let verb: String

    package var timeCategory: AgentTimeCategory? { AgentTimeCategory(rawValue: category) }

    enum CodingKeys: String, CodingKey {
        case start, end, category, verb
        case toolClass = "tool_class"
    }
}

package struct AgentLane: Decodable, Equatable, Sendable {
    package let agentID: String
    package let subagentType: String
    package let background: Bool
    package let segments: [AgentSegment]

    enum CodingKeys: String, CodingKey {
        case background, segments
        case agentID = "agent_id", subagentType = "subagent_type"
    }
}

/// `agents report --json`: one workbench over a period.
package struct AgentReportOverview: Decodable, Equatable, Sendable {
    package let workbenchID: Int64
    package let enabled: Bool
    package let since: String
    package let until: String
    package let totals: AgentReportTotals
    package let time: AgentTimeSplit
    package let subagents: AgentSubagents
    package let commands: [AgentCommandRow]
    package let models: [AgentModelRow]
    package let hints: [AgentHint]
    package let tasks: [AgentTaskRow]
    package let sessions: [AgentSessionRow]
    package let oldFormatSessions: Int

    enum CodingKeys: String, CodingKey {
        case enabled, since, until, totals, time, subagents, commands, models, hints, tasks, sessions
        case workbenchID = "workbench_id", oldFormatSessions = "old_format_sessions"
    }
}

/// `agents report --session <uuid> --json`: one session's drill-down.
package struct AgentSessionDetail: Decodable, Equatable, Sendable {
    package let session: AgentSessionRow
    package let time: AgentTimeSplit
    package let subagents: AgentSubagents
    package let hints: [AgentHint]
    package let lanes: [AgentLane]
    package let commands: [AgentCommandRow]
}
