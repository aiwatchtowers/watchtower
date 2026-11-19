import GRDB

/// Branch review's reviewer threads (board #1025, migration 00180): one
/// conversation per (workbench, folder, branch) since 00209, so two folders
/// with the same branch never share a thread. The folder is the reviewed
/// session's (`terminal_sessions.workbench_folder_id`); nil — a row without
/// one — is the workbench's home folder. Go writes it (`chat.reviewer_thread`).
package enum ReviewerThreadQueries {
    /// The thread's conversation, nil when the branch has none yet.
    package static func conversationID(_ db: Database, projectID: Int64, folderID: Int64? = nil, branch: String) throws -> Int64? {
        let (folderSQL, folderArg) = folder(projectID: projectID, folderID: folderID)
        return try Int64.fetchOne(db, sql: """
            SELECT conversation_id FROM review_reviewer_threads
            WHERE project_id = ? AND workbench_folder_id = \(folderSQL) AND branch = ?
            """, arguments: [projectID, folderArg, branch])
    }

    /// The folder key: the given id, else the home folder's subquery.
    package static func folder(projectID: Int64, folderID: Int64?) -> (sql: String, argument: Int64) {
        guard let folderID else { return (WorkbenchFolderQueries.homeFolderIDSQL, projectID) }
        return ("?", folderID)
    }
}
