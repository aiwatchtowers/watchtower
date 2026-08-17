import GRDB
import WatchtowerKit

package enum BriefingQueries {
    package static func fetchRecent(
        _ db: Database,
        limit: Int = 30,
        offset: Int = 0
    ) throws -> [Briefing] {
        try Briefing.fetchAll(
            db,
            sql: """
                SELECT * FROM briefings
                ORDER BY created_at DESC
                LIMIT ? OFFSET ?
                """,
            arguments: [limit, offset]
        )
    }

    package static func fetchByID(_ db: Database, id: Int) throws -> Briefing? {
        try Briefing.fetchOne(
            db,
            sql: "SELECT * FROM briefings WHERE id = ?",
            arguments: [id]
        )
    }

    /// Fetch the most recent briefing for a specific date (YYYY-MM-DD).
    package static func fetchByDate(_ db: Database, date: String) throws -> Briefing? {
        try Briefing.fetchOne(
            db,
            sql: "SELECT * FROM briefings WHERE date = ? ORDER BY created_at DESC LIMIT 1",
            arguments: [date]
        )
    }

    package static func fetchLatest(_ db: Database) throws -> Briefing? {
        try Briefing.fetchOne(
            db,
            sql: "SELECT * FROM briefings ORDER BY created_at DESC LIMIT 1"
        )
    }

    package static func markRead(_ db: Database, id: Int) throws {
        try db.execute(
            sql: """
                UPDATE briefings SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ? AND read_at IS NULL
                """,
            arguments: [id]
        )
    }

    /// Marks multiple briefings read in one write. No-op on empty input.
    package static func markRead(_ db: Database, ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: """
                UPDATE briefings SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id IN (\(placeholders)) AND read_at IS NULL
                """,
            arguments: StatementArguments(ids)
        )
    }

    package static func unreadCount(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM briefings WHERE read_at IS NULL"
        ) ?? 0
    }

    package static func maxID(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM briefings") ?? 0
    }

    package static func fetchNewSince(_ db: Database, afterID: Int) throws -> [Briefing] {
        try Briefing.fetchAll(
            db,
            sql: """
                SELECT * FROM briefings
                WHERE id > ?
                ORDER BY id ASC
                """,
            arguments: [afterID]
        )
    }
}
