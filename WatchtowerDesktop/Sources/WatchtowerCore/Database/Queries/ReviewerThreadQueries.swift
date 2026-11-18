import GRDB

/// Branch review's reviewer threads (board #1025, migration 00180): one
/// conversation per (workbench, folder, branch) since 00196. The Desktop is
/// the only writer. Until a review names its session's own folder (#2003),
/// every thread is the workbench's home folder's.
package enum ReviewerThreadQueries {
    /// The workbench's home folder row: its live folder whose path is
    /// `projects.folder_path`. Bound to the project id.
    private static let homeFolderSQL = """
        (SELECT f.id FROM workbench_folders f JOIN projects p ON p.id = f.workbench_id
         WHERE f.workbench_id = ? AND f.removed_at IS NULL AND f.folder_path = p.folder_path COLLATE NOCASE
         ORDER BY f.id LIMIT 1)
        """

    /// The thread's conversation, nil when the branch has none yet.
    package static func conversationID(_ db: Database, projectID: Int64, branch: String) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT conversation_id FROM review_reviewer_threads
            WHERE project_id = ? AND workbench_folder_id = \(homeFolderSQL) AND branch = ?
            """, arguments: [projectID, projectID, branch])
    }

    /// The thread's conversation, made with its row on first use. Read again
    /// inside the write: two sessions on one branch share one thread.
    package static func ensure(_ db: Database, projectID: Int64, branch: String) throws -> Int64 {
        if let existing = try conversationID(db, projectID: projectID, branch: branch) { return existing }
        let conversation = try ChatConversationQueries.create(
            db, title: "Reviewer: \(branch)", contextType: ReviewerSurface.contextType,
            contextID: ReviewerSurface.contextID(projectID: projectID, branch: branch))
        try db.execute(sql: """
            INSERT INTO review_reviewer_threads (project_id, workbench_folder_id, branch, conversation_id)
            VALUES (?, \(homeFolderSQL), ?, ?)
            """, arguments: [projectID, projectID, branch, conversation.id])
        return conversation.id
    }
}
