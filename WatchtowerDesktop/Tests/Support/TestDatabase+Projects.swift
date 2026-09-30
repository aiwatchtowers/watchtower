import Foundation
import GRDB

/// Fixtures for the Projects tables (spec §3). Project targets follow the
/// index's constraint: `level='custom'`, `custom_label='project'`,
/// `source_type='chat'`, `ownership='mine'`.
extension TestDatabase {
    @discardableResult
    package static func insertProject(
        _ db: Database,
        name: String = "acme",
        folder: String = "/tmp/acme"
    ) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO projects (name, folder_path) VALUES (?, ?)",
            arguments: [name, folder]
        )
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertProjectTarget(
        _ db: Database,
        projectID: Int64,
        text: String = "Feature",
        status: String = "todo",
        parentID: Int64? = nil
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO targets (text, level, custom_label, period_start, period_end,
                    parent_id, status, ownership, source_type, project_id)
                VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, 'mine', 'chat', ?)
                """,
            arguments: [text, parentID, status, projectID]
        )
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertProjectDocument(
        _ db: Database,
        projectID: Int64,
        relPath: String = "docs/plan.md",
        kind: String = "plan",
        title: String = "",
        targetID: Int64? = nil,
        updatedAt: String = "2026-09-29T10:00:00Z"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO project_documents (project_id, target_id, rel_path, kind, title, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [projectID, targetID, relPath, kind, title, updatedAt]
        )
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertProjectComment(
        _ db: Database,
        projectID: Int64,
        author: String = "agent",
        body: String = "Question?",
        targetID: Int64? = nil,
        documentID: Int64? = nil,
        parentID: Int64? = nil,
        status: String = "open",
        quote: String = "",
        readAt: String = ""
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO project_comments (project_id, target_id, document_id, parent_id,
                    author, body, anchor_quote, status, read_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [projectID, targetID, documentID, parentID, author, body, quote, status, readAt]
        )
        return db.lastInsertedRowID
    }
}
