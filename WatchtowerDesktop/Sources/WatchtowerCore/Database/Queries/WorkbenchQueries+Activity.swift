import Foundation
import GRDB

extension WorkbenchQueries {
    /// What the notification policy compares between polls (spec §6.5).
    /// `questions` = agent root comments on targets with id > the watermark;
    /// `openAsks` = the workbench's `owner_asks` still `open`;
    /// `ownerTouched` = the done targets the owner's own write closed, read
    /// from the history actor (`WorkbenchOwnerNoticePolicy`).
    package static func activitySnapshot(
        _ db: Database,
        project: Workbench,
        afterAgentCommentID: Int64
    ) throws -> WorkbenchNotificationPolicy.Snapshot {
        let last = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(MAX(id), 0) FROM project_comments
            WHERE project_id = ? AND author = 'agent' AND parent_id IS NULL AND target_id IS NOT NULL
            """, arguments: [project.id]) ?? 0
        let questionRows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.target_id, c.body, t.text AS target_title
            FROM project_comments c JOIN targets t ON t.id = c.target_id
            WHERE c.project_id = ? AND c.author = 'agent' AND c.parent_id IS NULL AND c.id > ?
            ORDER BY c.id
            """, arguments: [project.id, afterAgentCommentID])
        let questions = questionRows.map { row in
            WorkbenchNotificationPolicy.Question(
                id: row["id"], targetID: row["target_id"], targetTitle: row["target_title"], body: row["body"]
            )
        }
        var targets: [Int64: WorkbenchNotificationPolicy.TargetState] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, text, status FROM targets WHERE project_id = ?", arguments: [project.id]) {
            targets[row["id"]] = .init(title: row["text"], status: row["status"])
        }
        // Read raw, not as `OwnerAsk`: one undecodable payload must not
        // stop the workbench's notices.
        var asks: [Int64: WorkbenchNotificationPolicy.OpenAsk] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT id, title, session_id, kind FROM owner_asks WHERE project_id = ? AND status = 'open'
              AND \(OwnerAskQueries.notInSpecLoop("owner_asks"))
            """, arguments: [project.id]) {
            // An unknown kind reads as nil: the notice says "Agent asks".
            let kind = (row["kind"] as String?).flatMap(OwnerAskKind.init(rawValue:))
            asks[row["id"]] = .init(title: row["title"], sessionID: row["session_id"], kind: kind)
        }
        // Proposals the workbench session filed (`context_type='project'`, Go
        // `tools.WorkbenchContextType`) — only an External, propose-only tool
        // (a Slack send) stays pending there; the policy reads the new ones.
        let projectKey = String(project.id)
        let lastAction = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(MAX(id), 0) FROM agent_actions WHERE context_type = 'project' AND context_id = ?
            """, arguments: [projectKey]) ?? 0
        let pendingRows = try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions WHERE context_type = 'project' AND context_id = ? AND status = 'pending'
            ORDER BY id
            """, arguments: [projectKey])
        let pending = pendingRows.map { action in
            WorkbenchNotificationPolicy.PendingAction(
                id: action.id, tool: action.tool,
                summary: SlackSendProposal(action: action).map { "\($0.recipientLine) — \($0.text)" } ?? action.reason
            )
        }
        return WorkbenchNotificationPolicy.Snapshot(
            projectID: project.id, projectName: project.name, lastAgentCommentID: last,
            questions: questions, targets: targets,
            ownerTouched: WorkbenchOwnerNoticePolicy.ownerWritten(
                newestActors: try newestStatusActors(db, projectID: project.id)
            ),
            openAsks: asks,
            lastActionID: lastAction, pendingActions: pending
        )
    }

    /// For each workbench target that is `done` now (the only change the
    /// policy announces), the actor of its newest `target_status_history`
    /// row (by id), for `WorkbenchOwnerNoticePolicy`. A `system` row the
    /// rollup (PROJ-05) wrote in the same statement as a child's change takes
    /// that change's actor: the triggers write the child's row first and the
    /// parents' right after it, so the nearest earlier non-`system` row with
    /// the same `changed_at` in the same workbench is its cause. A target
    /// with no row is absent. Relies on `targets_status_history_au` writing
    /// the child's row before the rollup trigger's (trigger creation order,
    /// migration 00143); the rollup tests in WorkbenchOwnerNoticePolicyTests
    /// pin it.
    package static func newestStatusActors(_ db: Database, projectID: Int64) throws -> [Int64: String] {
        var actors: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT t.id,
                   CASE WHEN h.actor = 'system' AND o.changed_at = h.changed_at THEN o.actor
                        ELSE h.actor END AS actor
            FROM targets t
            JOIN target_status_history h
              ON h.id = (SELECT MAX(h2.id) FROM target_status_history h2 WHERE h2.target_id = t.id)
            LEFT JOIN target_status_history o
              ON h.actor = 'system'
             AND o.id = (SELECT MAX(o2.id) FROM target_status_history o2
                         JOIN targets t2 ON t2.id = o2.target_id
                         WHERE o2.id < h.id AND o2.actor != 'system' AND t2.project_id = t.project_id)
            WHERE t.project_id = ? AND t.status = 'done'
            """, arguments: [projectID]) {
            actors[row["id"]] = row["actor"]
        }
        return actors
    }
}
