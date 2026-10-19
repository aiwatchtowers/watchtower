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
    /// What to change; absent from a CLI older than v2.
    package let action: String?
    package let fix: AgentHintFix?
    package let moreEvidence: Int?
    package let estimateTokens: Int64?

    enum CodingKeys: String, CodingKey {
        case id, finding, evidence, action, fix
        case estimateMS = "estimate_ms", estimateUSD = "estimate_usd"
        case moreEvidence = "more_evidence", estimateTokens = "estimate_tokens"
    }
}

/// The change the app can make for a hint (`Fix` in `hints.go`).
package struct AgentHintFix: Decodable, Equatable, Sendable {
    package let kind: String
    package let ref: String?
    package let rules: [String]?
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

/// How far the workbench's history import got (`import` in the overview).
package struct AgentImportState: Decodable, Equatable, Sendable {
    /// `waiting_for_move`, `not_started`, `loading` or `done`.
    package let state: String
    package let filesStored: Int
    package let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case state
        case filesStored = "files_stored", updatedAt = "updated_at"
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
    /// Task rows Go's cap left out; absent from an older CLI.
    package let tasksMore: Int?
    package let sessions: [AgentSessionRow]
    package let oldFormatSessions: Int
    /// Absent from a CLI older than #849: no loading line.
    package let importState: AgentImportState?
    /// The v2 blocks; absent from an older CLI.
    package let context: AgentContextReport?
    package let skills: AgentSkillsReport?
    package let trouble: AgentTroubleReport?

    enum CodingKeys: String, CodingKey {
        case enabled, since, until, totals, time, subagents, commands, models, hints, tasks, sessions
        case context, skills, trouble
        case tasksMore = "tasks_more"
        case workbenchID = "workbench_id", oldFormatSessions = "old_format_sessions"
        case importState = "import"
    }
}

extension AgentReportOverview {
    /// The same report but for the `since`/`until` stamps, which Go sets
    /// from the clock on every run.
    package func sameReport(as other: Self) -> Bool {
        workbenchID == other.workbenchID && enabled == other.enabled && totals == other.totals
            && time == other.time && subagents == other.subagents && commands == other.commands
            && models == other.models && hints == other.hints && tasks == other.tasks
            && tasksMore == other.tasksMore
            && sessions == other.sessions && oldFormatSessions == other.oldFormatSessions
            && importState == other.importState && context == other.context
            && skills == other.skills && trouble == other.trouble
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

// MARK: - Context (`internal/agentreport/context.go`)

package struct AgentContextReport: Decodable, Equatable, Sendable {
    package let factsSessions: Int?
    package let sessions: Int?
    package let baseline: AgentBaselineSplit?
    package let subagentBaseline: AgentBaselineSplit?
    package let growth: [AgentGrowthRow]?
    package let topSources: [AgentSourceRow]?
    package let repeatedReads: [AgentRepeatRow]?
    package let compactions: AgentCompactionStats?
    package let disk: AgentDiskSizes?

    enum CodingKeys: String, CodingKey {
        case sessions, baseline, growth, compactions, disk
        case factsSessions = "facts_sessions", subagentBaseline = "subagent_baseline"
        case topSources = "top_sources", repeatedReads = "repeated_reads"
    }
}

package struct AgentBaselineSplit: Decodable, Equatable, Sendable {
    package let tokens: Int64?
    package let parts: [AgentPartShare]?
}

package struct AgentPartShare: Decodable, Equatable, Sendable {
    package let part: String
    package let tokens: Int64
    package let share: Double
}

package struct AgentGrowthRow: Decodable, Equatable, Sendable {
    package let source: String
    package let tokens: Int64
    package let share: Double
}

package struct AgentSourceRow: Decodable, Equatable, Sendable {
    package let tool: String
    package let target: String
    package let tokens: Int64
    package let calls: Int
    package let sessions: Int
}

package struct AgentRepeatRow: Decodable, Equatable, Sendable {
    package let target: String
    package let reads: Int
    package let sessionUUID: String
    package let tokens: Int64

    enum CodingKeys: String, CodingKey {
        case target, reads, tokens
        case sessionUUID = "session_uuid"
    }
}

package struct AgentCompactionStats: Decodable, Equatable, Sendable {
    package let count: Int
    package let medianPreTokens: Int64
    package let medianPostTokens: Int64
    package let sessions: Int

    enum CodingKeys: String, CodingKey {
        case count, sessions
        case medianPreTokens = "median_pre_tokens", medianPostTokens = "median_post_tokens"
    }
}

package struct AgentDiskSizes: Decodable, Equatable, Sendable {
    package let claudeMDBytes: Int64
    package let claudeMDLines: Int
    package let rulesBytes: Int64

    enum CodingKeys: String, CodingKey {
        case claudeMDBytes = "claude_md_bytes", claudeMDLines = "claude_md_lines"
        case rulesBytes = "rules_bytes"
    }
}

// MARK: - Skills (`internal/agentreport/skills.go`)

package struct AgentSkillsReport: Decodable, Equatable, Sendable {
    package let factsSessions: Int?
    package let listed: Int?
    package let used: Int?
    package let listingTokens: Int64?
    package let rows: [AgentSkillRow]?
    package let neverUsed: [AgentUnusedSkill]?

    enum CodingKeys: String, CodingKey {
        case listed, used, rows
        case factsSessions = "facts_sessions", listingTokens = "listing_tokens"
        case neverUsed = "never_used"
    }
}

package struct AgentSkillRow: Decodable, Equatable, Sendable {
    package let name: String
    package let invocations: Int
    /// `proactive`, `slash`, `read`.
    package let byTrigger: [String: Int]
    package let costUSD: Double
    package let sessions: Int

    enum CodingKeys: String, CodingKey {
        case name, invocations, sessions
        case byTrigger = "by_trigger", costUSD = "cost_usd"
    }
}

package struct AgentUnusedSkill: Decodable, Equatable, Sendable {
    package let name: String
    package let listingTokens: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case listingTokens = "listing_tokens"
    }
}

// MARK: - Trouble (`internal/agentreport/trouble.go`)

package struct AgentTroubleReport: Decodable, Equatable, Sendable {
    package let classes: [AgentErrorClassRow]?
    package let denials: [AgentDenialRow]?
    package let interrupts: Int?
    package let rejections: Int?
    package let interruptSessions: [AgentSessionCount]?
    package let unfinishedSubagents: Int?
    package let rateLimited: Int?
    package let factsSessions: Int?

    enum CodingKeys: String, CodingKey {
        case classes, denials, interrupts, rejections
        case interruptSessions = "interrupt_sessions", unfinishedSubagents = "unfinished_subagents"
        case rateLimited = "rate_limited", factsSessions = "facts_sessions"
    }
}

package struct AgentErrorClassRow: Decodable, Equatable, Sendable {
    package let `class`: String
    package let tool: String
    package let count: Int
    package let sessions: [AgentSessionCount]
}

package struct AgentSessionCount: Decodable, Equatable, Sendable {
    package let sessionUUID: String
    package let count: Int

    enum CodingKeys: String, CodingKey {
        case count
        case sessionUUID = "session_uuid"
    }
}

package struct AgentDenialRow: Decodable, Equatable, Sendable {
    /// `automode-blocked`, `permission-rule`, `user-rejected`.
    package let kind: String
    package let tool: String
    package let target: String
    package let count: Int
}
