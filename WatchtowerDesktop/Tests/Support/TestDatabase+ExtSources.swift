import Foundation
import GRDB

/// External-source (Confluence) fixtures, kept out of `TestDatabase.swift`,
/// which is at its SwiftLint file-length ceiling (the
/// `TestDatabase+AgentActions` precedent).
extension TestDatabase {
    /// Insert one Jira-account-scoped `ext_sources` row and return its id.
    @discardableResult
    package static func insertExtSource(
        _ db: Database,
        jiraAccountID: Int64,
        containerKey: String,
        containerName: String = "",
        status: String = "ok",
        error: String = "",
        backfillDone: Bool = false,
        lastSyncedAt: String = ""
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO ext_sources
                    (provider, jira_account_id, container_key, container_ext_id, container_name,
                     status, error, backfill_done, last_synced_at)
                VALUES ('confluence', ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                jiraAccountID, containerKey, "sp-\(containerKey)", containerName,
                status, error, backfillDone, lastSyncedAt
            ]
        )
        return db.lastInsertedRowID
    }

    /// Insert one `ext_documents` row of `kind` (page/blogpost/attachment).
    package static func insertExtDocument(
        _ db: Database,
        sourceID: Int64,
        extID: String,
        kind: String = "page",
        title: String = ""
    ) throws {
        try db.execute(
            sql: "INSERT INTO ext_documents (source_id, ext_id, kind, title) VALUES (?, ?, ?, ?)",
            arguments: [sourceID, extID, kind, title]
        )
    }
}
