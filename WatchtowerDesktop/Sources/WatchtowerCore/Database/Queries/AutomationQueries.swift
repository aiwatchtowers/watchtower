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

    /// The runs with these ids in one SELECT (the quick-run finish watch);
    /// a missing id is absent, and no ids run no query.
    package static func fetchRuns(_ db: Database, ids: [Int64]) throws -> [AutomationRun] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try AutomationRun.fetchAll(db, sql: "SELECT * FROM automation_runs WHERE id IN (\(marks))",
                                          arguments: StatementArguments(ids))
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
    /// "⚙ <name> · run #<id>" for each ask an automation run filed
    /// (`ask()`, spec §13.3); an agent's ask, or a missing one, is absent.
    package static func askLabels(_ db: Database, askIDs: [Int64]) throws -> [Int64: String] {
        guard !askIDs.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: askIDs.count).joined(separator: ",")
        var out: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT q.id, q.automation_run_id AS run_id, COALESCE(NULLIF(a.name, ''), a.slug) AS name
            FROM owner_asks q JOIN automation_runs r ON r.id = q.automation_run_id
            JOIN automations a ON a.id = r.automation_id
            WHERE q.id IN (\(marks))
            """, arguments: StatementArguments(askIDs)) {
            let id: Int64 = row["id"]
            let runID: Int64 = row["run_id"]
            let name: String = row["name"]
            out[id] = "⚙ \(name) · run #\(runID)"
        }
        return out
    }

    // MARK: - Workbench sessions (P5, spec §13.1)

    /// A session step's `args_json` as Go's SDK writes it, agent and title
    /// resolved.
    private struct SessionStepArgs: Decodable {
        let prompt: String
        let agent: String
        let title: String
    }

    /// The `session()` steps of workbench runs waiting for the app — step
    /// waiting with no session attached, run waiting with reason `app` — in
    /// step order (Go's `PendingAutomationSessionSteps`). A step whose args
    /// cannot be read is left out and named in `unreadable` (the caller logs
    /// it once): Go validated them, so such a row is broken, and its run
    /// waits until its pause timeout.
    package static func fetchPendingSessionRequests(_ db: Database) throws
        -> (requests: [PendingSessionRequest], unreadable: [Int64]) {
        let rows = try Row.fetchAll(db, sql: """
            SELECT st.id, st.run_id, a.id AS automation_id, a.project_id, st.args_json,
                COALESCE(NULLIF(a.name, ''), a.slug) AS name
            FROM automation_run_steps st
            JOIN automation_runs r ON r.id = st.run_id
            JOIN automations a ON a.id = r.automation_id
            WHERE st.kind = 'session' AND st.status = 'waiting' AND st.session_id IS NULL AND st.finished_at IS NULL
              AND r.status = 'waiting' AND r.waiting_reason = 'app'
              AND a.scope = 'workbench' AND a.project_id IS NOT NULL
            ORDER BY st.id
            """)
        var requests: [PendingSessionRequest] = []
        var unreadable: [Int64] = []
        for row in rows {
            let stepID: Int64 = row["id"]
            let runID: Int64 = row["run_id"]
            let name: String = row["name"]
            let json: String = row["args_json"]
            guard let args = try? JSONDecoder().decode(SessionStepArgs.self, from: Data(json.utf8)),
                  !args.prompt.isEmpty, let agent = AgentKind(rawValue: args.agent) else {
                unreadable.append(stepID)
                continue
            }
            requests.append(PendingSessionRequest(
                stepID: stepID, runID: runID, automationID: row["automation_id"], projectID: row["project_id"],
                automationName: name, prompt: args.prompt,
                title: args.title.isEmpty ? "⚙ \(name) · run #\(runID)" : args.title, agent: agent
            ))
        }
        return (requests, unreadable)
    }

    /// A session of run `runID` that no step names: the app created it but
    /// did not attach it (a crash between the two), so it is adopted rather
    /// than a second one launched. The oldest such row.
    package static func unattachedSession(_ db: Database, runID: Int64) throws -> TerminalSession? {
        try TerminalSession.fetchOne(db, sql: """
            SELECT * FROM terminal_sessions s WHERE s.automation_run_id = ?
              AND NOT EXISTS (SELECT 1 FROM automation_run_steps st WHERE st.session_id = s.id)
            ORDER BY s.id LIMIT 1
            """, arguments: [runID])
    }

    /// Takes the run marker off run `runID`'s sessions that no step names —
    /// the row a refused launch left — so no later poll adopts one (Go
    /// attaches only a session of the step's run). The rows stay; returns
    /// their ids.
    @discardableResult
    package static func disownUnattachedSessions(_ db: Database, runID: Int64) throws -> [Int64] {
        let ids = try Int64.fetchAll(db, sql: """
            SELECT s.id FROM terminal_sessions s WHERE s.automation_run_id = ?
              AND NOT EXISTS (SELECT 1 FROM automation_run_steps st WHERE st.session_id = s.id)
            ORDER BY s.id
            """, arguments: [runID])
        guard !ids.isEmpty else { return [] }
        try db.execute(sql: """
            UPDATE terminal_sessions SET automation_run_id = NULL WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            """, arguments: StatementArguments(ids))
        return ids
    }

    /// The `session()` steps still waiting on a session attached to them,
    /// their run still waiting: the sessions whose end the app reports. A
    /// session that finished or failed, or whose row is gone, is left out —
    /// the run's wait reads those ends itself (spec §13.1).
    package static func waitingSessionSteps(_ db: Database) throws -> [(stepID: Int64, sessionID: Int64)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT st.id, st.session_id FROM automation_run_steps st JOIN automation_runs r ON r.id = st.run_id
            JOIN terminal_sessions s ON s.id = st.session_id
            WHERE st.kind = 'session' AND st.status = 'waiting'
              AND st.finished_at IS NULL AND r.status = 'waiting'
              AND s.finished_at IS NULL AND s.agent_failed_at IS NULL
            ORDER BY st.id
            """)
        return rows.map { (stepID: $0["id"], sessionID: $0["session_id"]) }
    }

    // MARK: - Workbench header buttons (P5, spec §12.4)

    private struct ButtonSpec: Decodable {
        struct Button: Decodable {
            let label: String?
            let confirm: Bool

            enum CodingKeys: String, CodingKey { case label, confirm }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                label = try c.decodeIfPresent(String.self, forKey: .label)
                confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? false
            }
        }

        let button: Button?
    }

    /// Every not-removed `trigger.button` recipe of workbench `projectID`, in
    /// slug order. A spec without a label shows the recipe's name.
    package static func headerButtons(_ db: Database, projectID: Int64) throws -> [AutomationHeaderButton] {
        let automations = try Automation.fetchAll(db, sql: """
            SELECT * FROM automations
            WHERE scope = 'workbench' AND project_id = ? AND trigger_kind = 'button' AND removed_at IS NULL
            ORDER BY slug, id
            """, arguments: [projectID])
        guard !automations.isEmpty else { return [] }
        let active = try newestRunPerAutomation(db, active: true)
        return automations.map { a in
            let spec = try? JSONDecoder().decode(ButtonSpec.self, from: Data(a.triggerSpecJSON.utf8))
            let label = spec?.button?.label.flatMap { $0.isEmpty ? nil : $0 } ?? (a.name.isEmpty ? a.slug : a.name)
            return AutomationHeaderButton(
                automationID: a.id, slug: a.slug, label: label, confirm: spec?.button?.confirm ?? false,
                state: AutomationHeaderButton.state(of: a), activeRunID: active[a.id]?.id
            )
        }
    }
}
