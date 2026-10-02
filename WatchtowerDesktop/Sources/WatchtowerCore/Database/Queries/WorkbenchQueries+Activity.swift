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
        // Targets whose latest status change is the owner's own move to
        // in_review: their documents are not announced back to the owner.
        let ownerReviews = Set(try Int64.fetchAll(db, sql: """
            SELECT h.target_id FROM target_status_history h
            JOIN targets t ON t.id = h.target_id
            WHERE t.project_id = ? AND h.to_status = 'in_review' AND h.actor = 'owner'
              AND h.id = (SELECT MAX(id) FROM target_status_history WHERE target_id = h.target_id)
            """, arguments: [project.id]))
        var documents: [Int64: WorkbenchNotificationPolicy.DocumentState] = [:]
        for item in try documentListItems(db, projectID: project.id) {
            documents[item.id] = .init(
                title: item.document.displayTitle, updatedAt: item.document.updatedAt,
                openOwnerComments: item.openComments, imported: !item.document.isAgentAttached,
                awaitingReview: item.awaitingReview && !ownerReviews.contains(item.document.targetID ?? 0)
            )
        }
        var targets: [Int64: WorkbenchNotificationPolicy.TargetState] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, text, status FROM targets WHERE project_id = ?", arguments: [project.id]) {
            targets[row["id"]] = .init(title: row["text"], status: row["status"])
        }
        return WorkbenchNotificationPolicy.Snapshot(
            projectID: project.id, projectName: project.name, lastAgentCommentID: last,
            questions: questions, documents: documents, targets: targets, ownerTouched: []
        )
    }
}
