import GRDB

/// Branch review's reviewer threads (board #1025, migration 00180): one
/// conversation per (workbench, branch). Go writes it (`chat.reviewer_thread`).
package enum ReviewerThreadQueries {
    /// The thread's conversation, nil when the branch has none yet.
    package static func conversationID(_ db: Database, projectID: Int64, branch: String) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT conversation_id FROM review_reviewer_threads WHERE project_id = ? AND branch = ?
            """, arguments: [projectID, branch])
    }

}
