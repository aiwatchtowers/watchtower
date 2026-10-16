import Foundation
import GRDB

/// Reads of the automation tables. The only Swift writes are an inbox
/// output's `read_at` and `dismissed_at` (spec §9.6); everything else goes
/// through `AutomationsCLI`.
package enum AutomationQueries {
    /// R-P3-6: "tokens this week" is the CLI's rolling 7 days.
    package static let tokenWindow: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - List

    /// The indexed recipes whose file is present, by name.
    package static func fetchList(_ db: Database, now: Date) throws -> [AutomationListItem] {
        let automations = try Automation.fetchAll(db, sql: """
            SELECT * FROM automations WHERE removed_at IS NULL ORDER BY name COLLATE NOCASE, id
            """)
        guard !automations.isEmpty else { return [] }

        var tokens: [Int64: Int64] = [:]
        let since = AutomationDates.format(now.addingTimeInterval(-tokenWindow))
        for row in try Row.fetchAll(db, sql: """
            SELECT automation_id, SUM(input_tokens + output_tokens) AS tokens FROM automation_runs
            WHERE started_at >= ? GROUP BY automation_id
            """, arguments: [since]) {
            tokens[row["automation_id"]] = row["tokens"]
        }

        let lastRuns = try newestRunPerAutomation(db, active: false)
        let activeRuns = try newestRunPerAutomation(db, active: true)
        let grants = Dictionary(grouping: try AutomationToolGrant.fetchAll(db, sql: "SELECT * FROM automation_tool_grants"),
                                by: \.automationID)

        return automations.map { a in
            AutomationListItem(
                automation: a,
                lastRun: lastRuns[a.id],
                activeRun: activeRuns[a.id],
                tokens7d: tokens[a.id] ?? 0,
                badges: AutomationListItem.badges(for: a, grants: grants[a.id] ?? []),
                triggerText: AutomationTriggerText.describe(kind: a.triggerKind, specJSON: a.triggerSpecJSON)
            )
        }
    }

    /// One indexed recipe, removed or not; nil when the row is gone.
    package static func fetchAutomation(_ db: Database, id: Int64) throws -> Automation? {
        try Automation.fetchOne(db, sql: "SELECT * FROM automations WHERE id = ?", arguments: [id])
    }

    private static let activeStatuses = "('queued','running','waiting')"

    private static func newestRunPerAutomation(_ db: Database, active: Bool) throws -> [Int64: AutomationRun] {
        let filter = active ? "IN \(activeStatuses)" : "NOT IN \(activeStatuses)"
        let runs = try AutomationRun.fetchAll(db, sql: """
            SELECT * FROM automation_runs WHERE id IN (
                SELECT MAX(id) FROM automation_runs WHERE status \(filter) GROUP BY automation_id)
            """)
        return Dictionary(uniqueKeysWithValues: runs.map { ($0.automationID, $0) })
    }

    // MARK: - Card

    package static func fetchRuns(_ db: Database, automationID: Int64, limit: Int) throws -> [AutomationRun] {
        try AutomationRun.fetchAll(db, sql: """
            SELECT * FROM automation_runs WHERE automation_id = ? ORDER BY id DESC LIMIT ?
            """, arguments: [automationID, limit])
    }

    package static func fetchSteps(_ db: Database, runID: Int64) throws -> [AutomationRunStep] {
        try AutomationRunStep.fetchAll(db, sql: """
            SELECT * FROM automation_run_steps WHERE run_id = ? ORDER BY seq
            """, arguments: [runID])
    }

    package static func fetchGrants(_ db: Database, automationID: Int64) throws -> [AutomationToolGrant] {
        try AutomationToolGrant.fetchAll(db, sql: """
            SELECT * FROM automation_tool_grants WHERE automation_id = ? ORDER BY tool
            """, arguments: [automationID])
    }

    package static func fetchReports(_ db: Database, automationID: Int64, limit: Int) throws -> [AutomationOutput] {
        try AutomationOutput.fetchAll(db, sql: """
            SELECT * FROM automation_outputs WHERE automation_id = ? AND kind = 'report'
            ORDER BY created_at DESC, id DESC LIMIT ?
            """, arguments: [automationID, limit])
    }

    // MARK: - Sidebar badge

    /// Automations needing confirmation + runs waiting on the owner (an
    /// approval or an ask — R-P3-7; a session or the app is not the owner).
    package static func attentionCount(_ db: Database) throws -> Int {
        let confirm = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM automations
            WHERE parse_error = '' AND removed_at IS NULL AND confirmed_hash != approval_hash
            """) ?? 0
        let waits = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM automation_runs WHERE status = 'waiting' AND waiting_reason IN ('approval','ask')
            """) ?? 0
        return confirm + waits
    }

    // MARK: - Inbox outputs

    private static let unreadInbox = "o.kind = 'inbox' AND o.read_at IS NULL AND o.dismissed_at IS NULL"

    /// Unread inbox outputs, newest first, with their automation's name.
    package static func fetchInboxOutputs(_ db: Database) throws -> [AutomationOutputCard] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT o.id, o.automation_id, o.run_id, o.title, o.body, o.priority, o.created_at,
                COALESCE(NULLIF(a.name, ''), a.slug) AS name
            FROM automation_outputs o JOIN automations a ON a.id = o.automation_id
            WHERE \(unreadInbox) ORDER BY o.created_at DESC, o.id DESC
            """)
        return rows.map { row in
            AutomationOutputCard(
                id: row["id"],
                automationID: row["automation_id"],
                automationName: row["name"],
                runID: row["run_id"],
                title: row["title"],
                body: row["body"],
                priority: row["priority"],
                createdAt: AutomationDates.parse(row["created_at"]) ?? .distantPast
            )
        }
    }

    package static func inboxOutputCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM automation_outputs o WHERE \(unreadInbox)") ?? 0
    }

    /// Done on an inbox output card: writes `read_at` only, once.
    package static func markOutputRead(_ db: Database, id: Int64, now: Date) throws {
        try db.execute(sql: """
            UPDATE automation_outputs SET read_at = ? WHERE id = ? AND read_at IS NULL AND dismissed_at IS NULL
            """, arguments: [AutomationDates.format(now), id])
    }

    /// Dismiss on an inbox output card: writes `dismissed_at` only, once.
    package static func dismissOutput(_ db: Database, id: Int64, now: Date) throws {
        try db.execute(sql: """
            UPDATE automation_outputs SET dismissed_at = ? WHERE id = ? AND read_at IS NULL AND dismissed_at IS NULL
            """, arguments: [AutomationDates.format(now), id])
    }

    // MARK: - Labels

    /// The automation a run belongs to; nil when the run is gone.
    package static func automationID(_ db: Database, runID: Int64) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT automation_id FROM automation_runs WHERE id = ?", arguments: [runID])
    }

    /// "⚙ <name> · run #<id>" for each run that exists; a missing run is
    /// absent from the map.
    package static func runLabels(_ db: Database, runIDs: [Int64]) throws -> [Int64: String] {
        guard !runIDs.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: runIDs.count).joined(separator: ",")
        var out: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT r.id, COALESCE(NULLIF(a.name, ''), a.slug) AS name FROM automation_runs r JOIN automations a ON a.id = r.automation_id
            WHERE r.id IN (\(marks))
            """, arguments: StatementArguments(runIDs)) {
            let id: Int64 = row["id"]
            let name: String = row["name"]
            out[id] = "⚙ \(name) · run #\(id)"
        }
        return out
    }
}
