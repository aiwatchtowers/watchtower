import Foundation
import GRDB

extension ProjectQueries {
    /// What the notification policy compares between polls (spec §6.5).
    /// `questions` = agent root comments on targets with id > the watermark.
    package static func activitySnapshot(
        _ db: Database,
        project: Project,
        afterAgentCommentID: Int64
    ) throws -> ProjectNotificationPolicy.Snapshot {
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
            ProjectNotificationPolicy.Question(
                id: row["id"], targetID: row["target_id"], targetTitle: row["target_title"], body: row["body"]
            )
        }
        var documents: [Int64: ProjectNotificationPolicy.DocumentState] = [:]
        for item in try documentListItems(db, projectID: project.id) {
            documents[item.id] = .init(
                title: item.document.displayTitle, updatedAt: item.document.updatedAt, openOwnerComments: item.openComments
            )
        }
        var targets: [Int64: ProjectNotificationPolicy.TargetState] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, text, status FROM targets WHERE project_id = ?", arguments: [project.id]) {
            targets[row["id"]] = .init(title: row["text"], status: row["status"])
        }
        return ProjectNotificationPolicy.Snapshot(
            projectID: project.id, projectName: project.name, lastAgentCommentID: last,
            questions: questions, documents: documents, targets: targets, ownerTouched: []
        )
    }
}
