import Foundation
import GRDB

/// DB access for the secretary memory vault index. Mirrors the Go read paths
/// (internal/db/memory.go): the SQLite side is a rebuildable mirror of the
/// markdown vault (MEM-02), so every query here is read-only — the app never
/// writes memory_* tables; file edits go to the vault and the pipeline
/// reconciles the index.
enum MemoryQueries {

    // MARK: - Fetch

    /// Browser list: non-tombstone nodes of one type (or all), newest-indexed
    /// first, joined with the dispute side table. Redirect tombstones and the
    /// mechanical map/index pages never appear (they are not nodes).
    static func fetchNodes(_ db: Database, type: String? = nil) throws -> [MemoryNodeListItem] {
        var sql = """
            SELECT n.id, n.type, n.tier, n.status, n.title, n.path, n.indexed_at,
                   n.subject, n.confidence, d.reason AS dispute_reason
            FROM memory_nodes n
            LEFT JOIN memory_dispute_flags d ON d.node_id = n.id
            WHERE n.status != 'tombstone'
            """
        var args: [any DatabaseValueConvertible] = []
        if let type {
            sql += " AND n.type = ?"
            args.append(type)
        }
        sql += " ORDER BY n.indexed_at DESC, n.id"
        return try MemoryNodeListItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    static func fetchNode(_ db: Database, id: String) throws -> MemoryNodeListItem? {
        try MemoryNodeListItem.fetchOne(
            db,
            sql: """
                SELECT n.id, n.type, n.tier, n.status, n.title, n.path, n.indexed_at,
                       n.subject, n.confidence, d.reason AS dispute_reason
                FROM memory_nodes n
                LEFT JOIN memory_dispute_flags d ON d.node_id = n.id
                WHERE n.id = ?
                """,
            arguments: [id]
        )
    }

    /// Full-text search over titles/bodies (mirrors Go SearchMemoryFTS):
    /// term-quoted input, tombstones excluded, best rank first.
    static func searchNodes(_ db: Database, query: String, limit: Int = 40) throws -> [MemorySearchHit] {
        let sanitized = SearchQueries.sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }
        return try MemorySearchHit.fetchAll(
            db,
            sql: """
                SELECT n.id, n.title, n.type,
                       snippet(memory_fts, -1, '', '', '…', 12) AS snippet
                FROM memory_fts fts
                JOIN memory_nodes n ON n.id = fts.id
                WHERE memory_fts MATCH ? AND n.status != 'tombstone'
                ORDER BY rank
                LIMIT ?
                """,
            arguments: [sanitized, limit]
        )
    }

    /// Resolves a wiki-link target to a node id: a raw node id wins, then the
    /// alias table (NOCASE), then nil. Follows one redirect hop so links to a
    /// merged-away node land on its survivor.
    static func resolveNodeID(_ db: Database, target: String) throws -> String? {
        var id: String? = try String.fetchOne(
            db, sql: "SELECT id FROM memory_nodes WHERE id = ?", arguments: [target]
        )
        if id == nil {
            id = try String.fetchOne(
                db, sql: "SELECT node_id FROM memory_aliases WHERE alias = ?", arguments: [target]
            )
        }
        guard let found = id else { return nil }
        let redirect: String? = try String.fetchOne(
            db,
            sql: "SELECT redirect_to FROM memory_nodes WHERE id = ? AND redirect_to IS NOT NULL AND redirect_to != ''",
            arguments: [found]
        )
        return redirect ?? found
    }

    static func fetchAliases(_ db: Database, nodeID: String) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT alias FROM memory_aliases WHERE node_id = ? ORDER BY alias",
            arguments: [nodeID]
        )
    }

    /// Titles for a set of node ids (wiki-link labels fall back to these).
    static func fetchTitles(_ db: Database, ids: [String]) throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: ids.count)
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, title FROM memory_nodes WHERE id IN (\(marks))",
            arguments: StatementArguments(ids)
        )
        var titles: [String: String] = [:]
        for row in rows {
            titles[row["id"]] = row["title"] ?? ""
        }
        return titles
    }

    // MARK: - Beliefs dashboard

    /// All non-tombstone beliefs with their subject entity's title and the
    /// dispute flag; disputed first, then shaken, then by confidence.
    static func fetchBeliefs(_ db: Database) throws -> [MemoryBeliefRow] {
        try MemoryBeliefRow.fetchAll(
            db,
            sql: """
                SELECT b.id, b.title, b.status, b.confidence,
                       COALESCE(s.title, '') AS subject_title,
                       d.reason AS dispute_reason
                FROM memory_nodes b
                LEFT JOIN memory_nodes s ON s.id = b.subject
                LEFT JOIN memory_dispute_flags d ON d.node_id = b.id
                WHERE b.type = 'belief' AND b.status != 'tombstone'
                ORDER BY (d.node_id IS NULL), (b.status != 'shaken'), b.confidence DESC, b.id
                """
        )
    }

    // MARK: - Counts

    /// Node counts per type for the filter chips (tombstones excluded).
    static func fetchTypeCounts(_ db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT type, COUNT(*) AS n FROM memory_nodes WHERE status != 'tombstone' GROUP BY type"
        )
        var counts: [String: Int] = [:]
        for row in rows {
            counts[row["type"]] = row["n"]
        }
        return counts
    }

    /// Pending dispute flags — the sidebar badge (a dispute needs the owner).
    static func fetchDisputedCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_dispute_flags") ?? 0
    }

}
