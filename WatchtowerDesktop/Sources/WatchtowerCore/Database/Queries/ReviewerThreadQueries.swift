import GRDB

/// Branch review's reviewer threads (board #1025, migration 00175): one
/// conversation per (workbench, branch). The Desktop is the only writer.
package enum ReviewerThreadQueries {
    /// The thread's conversation, nil when the branch has none yet.
    package static func conversationID(_ db: Database, projectID: Int64, branch: String) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT conversation_id FROM review_reviewer_threads WHERE project_id = ? AND branch = ?
            """, arguments: [projectID, branch])
    }

    /// The thread's conversation, made with its row on first use. Read again
    /// inside the write: two sessions on one branch share one thread.
    package static func ensure(_ db: Database, projectID: Int64, branch: String) throws -> Int64 {
        if let existing = try conversationID(db, projectID: projectID, branch: branch) { return existing }
        let conversation = try ChatConversationQueries.create(
            db, title: "Reviewer: \(branch)", contextType: ReviewerSurface.contextType,
            contextID: ReviewerSurface.contextID(projectID: projectID, branch: branch))
        try db.execute(sql: """
            INSERT INTO review_reviewer_threads (project_id, branch, conversation_id) VALUES (?, ?, ?)
            """, arguments: [projectID, branch, conversation.id])
        return conversation.id
    }
}
