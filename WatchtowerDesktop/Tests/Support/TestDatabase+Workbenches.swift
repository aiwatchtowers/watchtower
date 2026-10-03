import Foundation
import GRDB

/// Fixtures for the Projects tables (spec §3). Project targets follow the
/// index's constraint: `level='custom'`, `custom_label='project'`,
/// `source_type='chat'`, `ownership='mine'`.
extension TestDatabase {
    @discardableResult
    package static func insertWorkbench(
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
    package static func insertWorkbenchTarget(
        _ db: Database,
        projectID: Int64,
        text: String = "Feature",
        status: String = "todo",
        parentID: Int64? = nil,
        priority: String = "medium"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO targets (text, level, custom_label, period_start, period_end,
                    parent_id, status, priority, ownership, source_type, project_id)
                VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, ?, 'mine', 'chat', ?)
                """,
            arguments: [text, parentID, status, priority, projectID]
        )
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertWorkbenchTargetImage(
        _ db: Database,
        projectID: Int64,
        targetID: Int64,
        fileName: String = "shot.png",
        sha256: String = "abc",
        path: String = "/tmp/project_files/1/abc.png"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO project_target_images (project_id, target_id, file_name, mime, size, sha256, path)
                VALUES (?, ?, ?, 'image/png', 3, ?, ?)
                """,
            arguments: [projectID, targetID, fileName, sha256, path]
        )
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertWorkbenchComment(
        _ db: Database,
        projectID: Int64,
        author: String = "agent",
        body: String = "Question?",
        targetID: Int64? = nil,
        parentID: Int64? = nil,
        status: String = "open",
        readAt: String = ""
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO project_comments (project_id, target_id, parent_id, author, body, status, read_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [projectID, targetID, parentID, author, body, status, readAt]
        )
        return db.lastInsertedRowID
    }

    /// An `owner_asks` row the way Go's `ask_owner` files it. A review needs a
    /// `docPath`; an answered or delivered ask needs an `answer`. A nil
    /// `createdAt` is the column default (now).
    @discardableResult
    package static func insertOwnerAsk(
        _ db: Database,
        projectID: Int64,
        sessionID: Int64? = nil,
        kind: String = "question",
        title: String = "Which way?",
        payload: String = "{}",
        docPath: String = "",
        status: String = "open",
        answer: String = "",
        createdAt: String? = nil
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO owner_asks (project_id, session_id, kind, title, payload, doc_path, status, answer, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ','now')))
                """,
            arguments: [projectID, sessionID, kind, title, payload, docPath, status, answer, createdAt]
        )
        return db.lastInsertedRowID
    }
}
