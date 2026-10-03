import Foundation
import GRDB

extension WorkbenchQueries {
    /// What the notification policy compares between polls (spec §6.5).
    /// `questions` = agent root comments on targets with id > the watermark.
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
            questions: questions, documents: [:], targets: targets, ownerTouched: [],
            lastActionID: lastAction, pendingActions: pending
        )
    }
}
