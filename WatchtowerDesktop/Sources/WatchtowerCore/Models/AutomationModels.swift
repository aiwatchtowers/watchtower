import Foundation
import GRDB

// Read models of the automation tables (migrations 00113, 00117). Go owns
// every write except `automation_outputs.read_at`/`dismissed_at` (spec §9.6).

/// The UTC RFC 3339 timestamps Go writes into the automation tables
/// ("2006-01-02T15:04:05Z"); both directions pin UTC explicitly.
package enum AutomationDates {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    package static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return formatter.date(from: text) ?? fractional.date(from: text)
    }

    package static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

/// Decodes a `*_json` list column; an empty or undecodable column is `[]`.
private func decodeStringList(_ text: String?) -> [String] {
    guard let text, !text.isEmpty else { return [] }
    return (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
}

// MARK: - Automation

/// One indexed recipe (`automations`).
package struct Automation: FetchableRecord, Identifiable, Equatable, Sendable {
    package enum Scope: String, Sendable {
        case personal, workbench
    }

    package let id: Int64
    package let slug: String
    package let scope: Scope
    package let projectID: Int64?
    package let path: String
    package let name: String
    package let triggerKind: String
    package let triggerSpecJSON: String
    package let missedPolicy: String
    package let concurrency: Int
    package let budgetTokens: Int
    package let budgetMinutes: Int
    package let pauseTimeoutHours: Int
    package let permissions: [String]
    package let outputs: [String]
    package let recipeText: String
    package let contentHash: String
    package let approvalHash: String
    package let confirmedHash: String
    package let parseError: String
    package let enabled: Bool
    package let lastScheduledFor: Date?
    package let nextRunAt: Date?
    package let removedAt: Date?

    package init(
        id: Int64,
        slug: String,
        scope: Scope = .personal,
        projectID: Int64? = nil,
        path: String = "",
        name: String = "",
        triggerKind: String = "manual",
        triggerSpecJSON: String = #"{"manual":true}"#,
        missedPolicy: String = "run_once",
        concurrency: Int = 1,
        budgetTokens: Int = 50000,
        budgetMinutes: Int = 5,
        pauseTimeoutHours: Int = 72,
        permissions: [String] = [],
        outputs: [String] = [],
        recipeText: String = "",
        contentHash: String = "",
        approvalHash: String = "",
        confirmedHash: String = "",
        parseError: String = "",
        enabled: Bool = false,
        lastScheduledFor: Date? = nil,
        nextRunAt: Date? = nil,
        removedAt: Date? = nil
    ) {
        self.id = id
        self.slug = slug
        self.scope = scope
        self.projectID = projectID
        self.path = path
        self.name = name
        self.triggerKind = triggerKind
        self.triggerSpecJSON = triggerSpecJSON
        self.missedPolicy = missedPolicy
        self.concurrency = concurrency
        self.budgetTokens = budgetTokens
        self.budgetMinutes = budgetMinutes
        self.pauseTimeoutHours = pauseTimeoutHours
        self.permissions = permissions
        self.outputs = outputs
        self.recipeText = recipeText
        self.contentHash = contentHash
        self.approvalHash = approvalHash
        self.confirmedHash = confirmedHash
        self.parseError = parseError
        self.enabled = enabled
        self.lastScheduledFor = lastScheduledFor
        self.nextRunAt = nextRunAt
        self.removedAt = removedAt
    }

    package init(row: Row) throws {
        id = row["id"]
        slug = row["slug"]
        // The CHECK admits only these two; a workbench row always carries project_id.
        scope = Scope(rawValue: row["scope"] ?? "") ?? .personal
        projectID = row["project_id"]
        path = row["path"]
        name = row["name"]
        triggerKind = row["trigger_kind"]
        triggerSpecJSON = row["trigger_spec"]
        missedPolicy = row["missed_policy"]
        concurrency = row["concurrency"]
        budgetTokens = row["budget_tokens"]
        budgetMinutes = row["budget_minutes"]
        pauseTimeoutHours = row["pause_timeout_hours"]
        permissions = decodeStringList(row["permissions_json"])
        outputs = decodeStringList(row["outputs_json"])
        recipeText = row["recipe_text"]
        contentHash = row["content_hash"]
        approvalHash = row["approval_hash"]
        confirmedHash = row["confirmed_hash"]
        parseError = row["parse_error"]
        enabled = row["enabled"]
        lastScheduledFor = AutomationDates.parse(row["last_scheduled_for"])
        nextRunAt = AutomationDates.parse(row["next_run_at"])
        removedAt = AutomationDates.parse(row["removed_at"])
    }

    /// "Needs your confirmation" (spec §2.5): a parsed, present recipe whose
    /// approval hash the owner has not confirmed.
    package var needsConfirmation: Bool {
        parseError.isEmpty && removedAt == nil && confirmedHash != approvalHash
    }

    /// Go `(Automation).Runnable()` (internal/db/automations.go): parsed,
    /// enabled, its file present, and confirmed at exactly the current hash.
    package var isRunnable: Bool {
        parseError.isEmpty && enabled && removedAt == nil && !confirmedHash.isEmpty && confirmedHash == approvalHash
    }
}

// MARK: - Runs

package enum StatusBadge: Sendable {
    case green, blue, red, orange, grey
}

package enum AutomationRunStatus: String, Sendable {
    case queued, running, waiting, succeeded, failed
    case budgetExceeded = "budget_exceeded"
    case timedOut = "timed_out"
    case cancelled, expired

    /// Not finished yet: the executor still owns the run.
    package var isActive: Bool {
        switch self {
        case .queued, .running, .waiting: true
        default: false
        }
    }

    /// Spec §12.1: succeeded green, running/waiting blue, failed/timed_out/
    /// expired red, budget_exceeded orange, cancelled grey. Queued is not in
    /// the spec's list; it is in progress, so blue like running.
    package var badge: StatusBadge {
        switch self {
        case .succeeded: .green
        case .queued, .running, .waiting: .blue
        case .failed, .timedOut, .expired: .red
        case .budgetExceeded: .orange
        case .cancelled: .grey
        }
    }
}

/// One run (`automation_runs`, spec §9.2).
package struct AutomationRun: FetchableRecord, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let automationID: Int64
    package let trigger: String
    package let scheduledFor: Date?
    package let rerunOf: Int64?
    package let status: AutomationRunStatus
    package let waitingReason: String
    package let recipeHash: String
    package let budgetTokens: Int
    package let budgetMinutes: Int
    package let inputTokens: Int64
    package let outputTokens: Int64
    package let tokensEstimated: Bool
    package let reportedCostUSD: Double?
    package let activeMS: Int64
    package let error: String
    package let errorKind: String
    package let summary: String
    package let queuedAt: Date?
    package let startedAt: Date?
    package let finishedAt: Date?

    package init(row: Row) throws {
        id = row["id"]
        automationID = row["automation_id"]
        trigger = row["trigger"]
        scheduledFor = AutomationDates.parse(row["scheduled_for"])
        rerunOf = row["rerun_of"]
        let rawStatus: String = row["status"]
        guard let status = AutomationRunStatus(rawValue: rawStatus) else {
            throw DatabaseError(message: "automation_runs.status \(rawStatus) is unknown")
        }
        self.status = status
        waitingReason = row["waiting_reason"]
        recipeHash = row["recipe_hash"]
        budgetTokens = row["budget_tokens"]
        budgetMinutes = row["budget_minutes"]
        inputTokens = row["input_tokens"]
        outputTokens = row["output_tokens"]
        tokensEstimated = row["tokens_estimated"]
        reportedCostUSD = row["reported_cost_usd"]
        activeMS = row["active_ms"]
        error = row["error"]
        errorKind = row["error_kind"]
        summary = row["summary"]
        queuedAt = AutomationDates.parse(row["queued_at"])
        startedAt = AutomationDates.parse(row["started_at"])
        finishedAt = AutomationDates.parse(row["finished_at"])
    }

    package var totalTokens: Int64 { inputTokens + outputTokens }
    package var isDryRun: Bool { trigger == "dry_run" }
}

/// One journal step (`automation_run_steps`, spec §9.3).
package struct AutomationRunStep: FetchableRecord, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let runID: Int64
    package let seq: Int
    package let kind: String
    package let name: String
    package let argsJSON: String
    package let resultSummary: String
    package let status: String
    package let auto: Bool
    package let permission: String
    package let actionID: Int64?
    package let askID: Int64?
    package let sessionID: Int64?
    package let inputTokens: Int64
    package let outputTokens: Int64
    package let tokensEstimated: Bool
    package let reportedCostUSD: Double?
    package let durationMS: Int64
    package let error: String
    package let startedAt: Date?
    package let finishedAt: Date?

    package init(
        id: Int64 = 0,
        runID: Int64 = 0,
        seq: Int = 0,
        kind: String,
        name: String = "",
        argsJSON: String = "",
        resultSummary: String = "",
        status: String,
        auto: Bool = false,
        permission: String = "",
        actionID: Int64? = nil,
        askID: Int64? = nil,
        sessionID: Int64? = nil,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        tokensEstimated: Bool = false,
        reportedCostUSD: Double? = nil,
        durationMS: Int64 = 0,
        error: String = "",
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.seq = seq
        self.kind = kind
        self.name = name
        self.argsJSON = argsJSON
        self.resultSummary = resultSummary
        self.status = status
        self.auto = auto
        self.permission = permission
        self.actionID = actionID
        self.askID = askID
        self.sessionID = sessionID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.tokensEstimated = tokensEstimated
        self.reportedCostUSD = reportedCostUSD
        self.durationMS = durationMS
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    package init(row: Row) throws {
        self.init(
            id: row["id"],
            runID: row["run_id"],
            seq: row["seq"],
            kind: row["kind"],
            name: row["name"],
            argsJSON: row["args_json"],
            resultSummary: row["result_summary"],
            status: row["status"],
            auto: row["auto"],
            permission: row["permission"],
            actionID: row["action_id"],
            askID: row["ask_id"],
            sessionID: row["session_id"],
            inputTokens: row["input_tokens"],
            outputTokens: row["output_tokens"],
            tokensEstimated: row["tokens_estimated"],
            reportedCostUSD: row["reported_cost_usd"],
            durationMS: row["duration_ms"],
            error: row["error"],
            startedAt: AutomationDates.parse(row["started_at"]),
            finishedAt: AutomationDates.parse(row["finished_at"])
        )
    }
}

// MARK: - Outputs and grants

/// One output (`automation_outputs`, spec §9.2).
package struct AutomationOutput: FetchableRecord, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let automationID: Int64
    package let runID: Int64
    package let kind: String
    package let title: String
    package let body: String
    package let priority: String
    package let createdAt: Date?
    package let readAt: Date?
    package let dismissedAt: Date?

    package init(row: Row) throws {
        id = row["id"]
        automationID = row["automation_id"]
        runID = row["run_id"]
        kind = row["kind"]
        title = row["title"]
        body = row["body"]
        priority = row["priority"]
        createdAt = AutomationDates.parse(row["created_at"])
        readAt = AutomationDates.parse(row["read_at"])
        dismissedAt = AutomationDates.parse(row["dismissed_at"])
    }
}

/// An unread `kind='inbox'` output as the Inbox action strip shows it.
package struct AutomationOutputCard: Identifiable, Equatable, Sendable {
    package let id: Int64
    package let automationID: Int64
    package let automationName: String
    package let runID: Int64
    package let title: String
    package let body: String
    package let priority: String
    package let createdAt: Date

    package init(
        id: Int64,
        automationID: Int64,
        automationName: String,
        runID: Int64,
        title: String,
        body: String,
        priority: String,
        createdAt: Date
    ) {
        self.id = id
        self.automationID = automationID
        self.automationName = automationName
        self.runID = runID
        self.title = title
        self.body = body
        self.priority = priority
        self.createdAt = createdAt
    }
}

/// One auto grant (`automation_tool_grants`, spec §9.4).
package struct AutomationToolGrant: FetchableRecord, Equatable, Sendable {
    package let automationID: Int64
    package let tool: String
    package let grantHash: String
    package let grantedAt: Date

    package init(automationID: Int64, tool: String, grantHash: String, grantedAt: Date) {
        self.automationID = automationID
        self.tool = tool
        self.grantHash = grantHash
        self.grantedAt = grantedAt
    }

    package init(row: Row) throws {
        automationID = row["automation_id"]
        tool = row["tool"]
        grantHash = row["grant_hash"]
        grantedAt = AutomationDates.parse(row["granted_at"]) ?? .distantPast
    }

    /// Spec §6.4: a grant is active only at the hash it was granted for; one
    /// whose recipe changed is kept for display as "Auto paused".
    package func isActive(approvalHash: String) -> Bool {
        !grantHash.isEmpty && grantHash == approvalHash
    }
}

// MARK: - List

package enum AutomationRowBadge: Equatable, Sendable {
    case needsConfirmation, autoPaused, disabled, parseError
}

/// One row of the Automations list.
package struct AutomationListItem: Identifiable, Equatable, Sendable {
    package let automation: Automation
    /// The newest finished run (dry runs included).
    package let lastRun: AutomationRun?
    /// The newest queued, running or waiting run.
    package let activeRun: AutomationRun?
    /// Input + output tokens of runs started in the last 7 days (R-P3-6).
    package let tokens7d: Int64
    package let badges: [AutomationRowBadge]
    package let triggerText: String

    package var id: Int64 { automation.id }

    package init(
        automation: Automation,
        lastRun: AutomationRun?,
        activeRun: AutomationRun?,
        tokens7d: Int64,
        badges: [AutomationRowBadge],
        triggerText: String
    ) {
        self.automation = automation
        self.lastRun = lastRun
        self.activeRun = activeRun
        self.tokens7d = tokens7d
        self.badges = badges
        self.triggerText = triggerText
    }

    /// The row's badges: a parse error alone (nothing else about the recipe
    /// is known), else needs confirmation / auto paused / disabled in that
    /// order. Auto paused mirrors Go's `anyGrantPaused`.
    package static func badges(for automation: Automation, grants: [AutomationToolGrant]) -> [AutomationRowBadge] {
        if !automation.parseError.isEmpty { return [.parseError] }
        var out: [AutomationRowBadge] = []
        if automation.needsConfirmation { out.append(.needsConfirmation) }
        if grants.contains(where: { !$0.isActive(approvalHash: automation.approvalHash) }) { out.append(.autoPaused) }
        if !automation.enabled { out.append(.disabled) }
        return out
    }
}
