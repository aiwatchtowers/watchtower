import Foundation
import GRDB

package enum ProjectQueryError: LocalizedError, Equatable {
    case emptyBody
    case noSubject
    case wrongProject
    case notARoot(Int64)
    case invalidStatus(String)

    package var errorDescription: String? {
        switch self {
        case .emptyBody: "A comment needs some text."
        case .noSubject: "A comment belongs to a target or a document."
        case .wrongProject: "That target or document belongs to another project."
        case let .notARoot(id): "Comment \(id) is a reply; only a thread's first comment has a status."
        case let .invalidStatus(status): "Unknown comment status \u{201C}\(status)\u{201D}."
        }
    }
}

/// Projects (spec §3, §6). The Go CLI and the project MCP server write
/// projects, sources, documents, targets and agent comments; the Desktop
/// writes only owner comments, root statuses and `read_at` — directly, the
/// targets dual-path precedent (Go twin: `internal/db/project_comments.go`,
/// whose reply-inherits-root rule this file mirrors).
package enum ProjectQueries {
    private static let now = "strftime('%Y-%m-%dT%H:%M:%SZ','now')"
    private static let statuses: Set<String> = ["open", "resolved", "outdated"]

    // MARK: - Projects

    package static func fetchAll(_ db: Database) throws -> [Project] {
        try Project.fetchAll(db, sql: "SELECT * FROM projects ORDER BY name COLLATE NOCASE, id")
    }

    package static func fetch(_ db: Database, id: Int64) throws -> Project? {
        try Project.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [id])
    }

    package static func summaries(_ db: Database) throws -> [ProjectSummary] {
        let projects = try fetchAll(db)
        let unread = try unreadCounts(db)
        var open: [Int64: Int] = [:]
        var active: [Int64: Int] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT project_id,
                   SUM(status IN ('todo','in_progress','blocked')) AS open_count,
                   SUM(status = 'in_progress') AS active_count
            FROM targets WHERE project_id IS NOT NULL GROUP BY project_id
            """)
        for row in rows {
            open[row["project_id"]] = row["open_count"]
            active[row["project_id"]] = row["active_count"]
        }
        var stamps: [Int64: [Int64: String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, project_id, updated_at FROM project_documents") {
            stamps[row["project_id"], default: [:]][row["id"]] = row["updated_at"]
        }
        return projects.map { project in
            ProjectSummary(
                project: project,
                openTargets: open[project.id] ?? 0,
                inProgressTargets: active[project.id] ?? 0,
                unreadAgentComments: unread[project.id] ?? 0,
                documentStamps: stamps[project.id] ?? [:]
            )
        }
    }

    // MARK: - Documents

    package static func documents(_ db: Database, projectID: Int64) throws -> [ProjectDocument] {
        try ProjectDocument.fetchAll(
            db,
            sql: "SELECT * FROM project_documents WHERE project_id = ? ORDER BY updated_at DESC, id DESC",
            arguments: [projectID]
        )
    }

    package static func document(_ db: Database, id: Int64) throws -> ProjectDocument? {
        try ProjectDocument.fetchOne(db, sql: "SELECT * FROM project_documents WHERE id = ?", arguments: [id])
    }

    /// The Documents pane's list row: each document with its linked target's
    /// title (if any) and its open owner-thread count.
    package static func documentListItems(_ db: Database, projectID: Int64) throws -> [ProjectDocumentListItem] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT d.*, t.text AS target_title,
                   (SELECT COUNT(*) FROM project_comments c
                    WHERE c.document_id = d.id AND c.parent_id IS NULL
                      AND c.author = 'owner' AND c.status = 'open') AS open_comments
            FROM project_documents d
            LEFT JOIN targets t ON t.id = d.target_id
            WHERE d.project_id = ?
            ORDER BY d.updated_at DESC, d.id DESC
            """, arguments: [projectID])
        return rows.map { row in
            ProjectDocumentListItem(
                document: ProjectDocument(row: row),
                targetTitle: row["target_title"],
                openComments: row["open_comments"]
            )
        }
    }

    // MARK: - Comments

    package static func comments(_ db: Database, documentID: Int64) throws -> [ProjectComment] {
        try ProjectComment.fetchAll(
            db,
            sql: "SELECT * FROM project_comments WHERE document_id = ? ORDER BY created_at, id",
            arguments: [documentID]
        )
    }

    package static func comments(_ db: Database, targetID: Int64) throws -> [ProjectComment] {
        try ProjectComment.fetchAll(
            db,
            sql: "SELECT * FROM project_comments WHERE target_id = ? ORDER BY created_at, id",
            arguments: [targetID]
        )
    }

    /// A new owner thread on a target or a document of `projectID`.
    @discardableResult
    package static func addOwnerComment(
        _ db: Database,
        projectID: Int64,
        targetID: Int64?,
        documentID: Int64?,
        anchor: CommentAnchor?,
        body: String
    ) throws -> Int64 {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProjectQueryError.emptyBody }
        guard targetID != nil || documentID != nil else { throw ProjectQueryError.noSubject }
        try requireInProject(db, projectID: projectID, table: "targets", id: targetID)
        try requireInProject(db, projectID: projectID, table: "project_documents", id: documentID)
        try db.execute(
            sql: """
                INSERT INTO project_comments (project_id, target_id, document_id, author, body,
                    anchor_quote, anchor_prefix, anchor_suffix, anchor_heading)
                VALUES (?, ?, ?, 'owner', ?, ?, ?, ?, ?)
                """,
            arguments: [
                projectID, targetID, documentID, text,
                anchor?.quote ?? "", anchor?.prefix ?? "", anchor?.suffix ?? "", anchor?.heading ?? ""
            ]
        )
        return db.lastInsertedRowID
    }

    /// An owner reply. It inherits the root's project, target and document —
    /// the same rule as Go `AddProjectComment`.
    @discardableResult
    package static func reply(_ db: Database, to rootID: Int64, body: String) throws -> Int64 {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProjectQueryError.emptyBody }
        guard let root = try ProjectComment.fetchOne(
            db, sql: "SELECT * FROM project_comments WHERE id = ?", arguments: [rootID]
        ), root.isRoot else { throw ProjectQueryError.notARoot(rootID) }
        try db.execute(
            sql: """
                INSERT INTO project_comments (project_id, target_id, document_id, parent_id, author, body)
                VALUES (?, ?, ?, ?, 'owner', ?)
                """,
            arguments: [root.projectID, root.targetID, root.documentID, root.id, text]
        )
        return db.lastInsertedRowID
    }

    package static func setStatus(_ db: Database, commentID: Int64, status: String) throws {
        guard statuses.contains(status) else { throw ProjectQueryError.invalidStatus(status) }
        try db.execute(
            sql: "UPDATE project_comments SET status = ? WHERE id = ? AND parent_id IS NULL",
            arguments: [status, commentID]
        )
        if db.changesCount == 0 { throw ProjectQueryError.notARoot(commentID) }
    }

    /// Marks unread agent comments read. A nil target/document id widens the
    /// scope; both nil = the whole project.
    package static func markAgentCommentsRead(
        _ db: Database,
        projectID: Int64,
        targetID: Int64?,
        documentID: Int64?
    ) throws {
        try db.execute(
            sql: """
                UPDATE project_comments SET read_at = \(now)
                WHERE project_id = ? AND author = 'agent' AND read_at = ''
                  AND (? IS NULL OR target_id = ?)
                  AND (? IS NULL OR document_id = ?)
                """,
            arguments: [projectID, targetID, targetID, documentID, documentID]
        )
    }

    /// Unread agent comments per project (projects with none are absent).
    package static func unreadCounts(_ db: Database) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT project_id, COUNT(*) AS n FROM project_comments
            WHERE author = 'agent' AND read_at = '' GROUP BY project_id
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { (row: Row) -> (Int64, Int) in
            (row["project_id"], row["n"])
        })
    }

    // MARK: - Board

    /// The project's target tree: roots (and orphans whose parent is outside
    /// the project) in status order in_progress, blocked, todo, done, others;
    /// then id. Children use the same order.
    package static func board(_ db: Database, projectID: Int64) throws -> [ProjectBoardNode] {
        let targets = try Target.fetchAll(
            db, sql: "SELECT * FROM targets WHERE project_id = ?", arguments: [projectID]
        )
        let counters = try boardCounters(db, projectID: projectID)
        let docs = Dictionary(grouping: try documents(db, projectID: projectID).filter { $0.targetID != nil }) {
            $0.targetID ?? 0
        }
        let ids = Set(targets.map(\.id))
        let byParent = Dictionary(grouping: targets) { target in
            target.parentId.flatMap { ids.contains($0) ? $0 : nil } ?? 0
        }
        func node(_ target: Target) -> ProjectBoardNode {
            let key = Int64(target.id)
            return ProjectBoardNode(
                target: target,
                children: sorted(byParent[target.id] ?? []).map(node),
                openComments: counters.open[key] ?? 0,
                unreadForOwner: counters.unread[key] ?? 0,
                documents: docs[key] ?? []
            )
        }
        return sorted(byParent[0] ?? []).map(node)
    }

    private static func boardCounters(_ db: Database, projectID: Int64) throws -> (open: [Int64: Int], unread: [Int64: Int]) {
        var open: [Int64: Int] = [:]
        var unread: [Int64: Int] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT target_id,
                   SUM(parent_id IS NULL AND status = 'open') AS open_count,
                   SUM(author = 'agent' AND read_at = '') AS unread_count
            FROM project_comments WHERE project_id = ? AND target_id IS NOT NULL
            GROUP BY target_id
            """, arguments: [projectID])
        for row in rows {
            open[row["target_id"]] = row["open_count"]
            unread[row["target_id"]] = row["unread_count"]
        }
        return (open, unread)
    }

    private static func sorted(_ targets: [Target]) -> [Target] {
        targets.sorted { lhs, rhs in
            let (lo, ro) = (statusRank(lhs.status), statusRank(rhs.status))
            return lo == ro ? lhs.id < rhs.id : lo < ro
        }
    }

    private static func statusRank(_ status: String) -> Int {
        switch status {
        case "in_progress": 0
        case "blocked": 1
        case "todo": 2
        case "done": 3
        default: 4
        }
    }

    private static func requireInProject(_ db: Database, projectID: Int64, table: String, id: Int64?) throws {
        guard let id else { return }
        let owner = try Int64.fetchOne(db, sql: "SELECT project_id FROM \(table) WHERE id = ?", arguments: [id])
        guard owner == projectID else { throw ProjectQueryError.wrongProject }
    }
}
