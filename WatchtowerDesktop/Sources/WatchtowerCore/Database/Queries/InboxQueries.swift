import Foundation
import GRDB
import WatchtowerKit

package enum InboxQueries {

    // MARK: - Fetch

    package static func fetchAll(
        _ db: Database,
        status: String? = nil,
        priority: String? = nil,
        triggerType: String? = nil,
        includeResolved: Bool = false,
        limit: Int = 200
    ) throws -> [InboxItem] {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let status {
            conditions.append("status = ?")
            args.append(status)
        } else if !includeResolved {
            conditions.append("status NOT IN ('resolved', 'dismissed')")
        }

        if let priority {
            conditions.append("priority = ?")
            args.append(priority)
        }

        if let triggerType {
            conditions.append("trigger_type = ?")
            args.append(triggerType)
        }

        var sql = "SELECT * FROM inbox_items"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += """
             ORDER BY \
            CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 1 END, \
            created_at DESC
            """
        sql += " LIMIT ?"
        args.append(limit)

        return try InboxItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    package static func fetchByID(_ db: Database, id: Int) throws -> InboxItem? {
        try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id])
    }

    // MARK: - Counts

    package static func fetchCounts(_ db: Database) throws -> (pending: Int, unread: Int, highPriority: Int) {
        let pending = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM inbox_items WHERE status = 'pending' AND archived_at IS NULL"
        ) ?? 0
        let unread = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM inbox_items
                WHERE status = 'pending' AND archived_at IS NULL
                  AND (read_at IS NULL OR read_at = '')
                """
        ) ?? 0
        let highPriority = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM inbox_items
                WHERE status = 'pending' AND archived_at IS NULL AND priority = 'high'
                """
        ) ?? 0
        return (pending, unread, highPriority)
    }

    // MARK: - Status Updates

    package static func resolve(_ db: Database, id: Int, reason: String = "Manually resolved") throws {
        try db.execute(
            sql: """
                UPDATE inbox_items SET status = 'resolved', resolved_reason = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [reason, id]
        )
    }

    package static func dismiss(_ db: Database, id: Int) throws {
        try db.execute(
            sql: """
                UPDATE inbox_items SET status = 'dismissed',
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [id]
        )
    }

    package static func snooze(_ db: Database, id: Int, until: String) throws {
        try db.execute(
            sql: """
                UPDATE inbox_items SET status = 'snoozed', snooze_until = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [until, id]
        )
    }

    // MARK: - Read

    package static func markRead(_ db: Database, id: Int) throws {
        try db.execute(
            sql: """
                UPDATE inbox_items SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ? AND (read_at IS NULL OR read_at = '')
                """,
            arguments: [id]
        )
    }

    /// Marks multiple inbox items read in one write. No-op on empty input.
    package static func markRead(_ db: Database, ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: """
                UPDATE inbox_items SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id IN (\(placeholders)) AND (read_at IS NULL OR read_at = '')
                """,
            arguments: StatementArguments(ids)
        )
    }

    // MARK: - Target

    package static func linkTarget(_ db: Database, inboxID: Int, targetID: Int) throws {
        try db.execute(
            sql: """
                UPDATE inbox_items SET target_id = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [targetID, inboxID]
        )
    }

    // MARK: - Action Tier / Awareness Tier / Seen

    /// Returns actionable pending items that are not archived, ordered by priority then updated_at DESC.
    /// When `unreadOnly` is true, hides items with a non-empty `read_at` unless their id is in `keepIDs`
    /// (the session-sticky set so just-read items don't vanish under the user's cursor).
    package static func fetchActionTier(
        _ db: Database,
        unreadOnly: Bool = false,
        keepIDs: Set<Int> = []
    ) throws -> [InboxItem] {
        var sql = """
            SELECT * FROM inbox_items
            WHERE item_class = 'actionable'
              AND status = 'pending'
              AND archived_at IS NULL
            """
        var args: [any DatabaseValueConvertible] = []
        if unreadOnly {
            if !keepIDs.isEmpty {
                let placeholders = keepIDs.map { _ in "?" }.joined(separator: ", ")
                sql += " AND ((read_at IS NULL OR read_at = '') OR id IN (\(placeholders)))"
                args.append(contentsOf: keepIDs.map { $0 as any DatabaseValueConvertible })
            } else {
                sql += " AND (read_at IS NULL OR read_at = '')"
            }
        }
        sql += """
             ORDER BY
              CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 1 END,
              updated_at DESC
            """
        return try InboxItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// Returns ambient, non-archived, active items ordered by created_at DESC with pagination.
    /// `unreadOnly` and `keepIDs` work the same as in `fetchActionTier`.
    package static func fetchAwarenessTier(
        _ db: Database,
        limit: Int,
        offset: Int,
        unreadOnly: Bool = false,
        keepIDs: Set<Int> = []
    ) throws -> [InboxItem] {
        var sql = """
            SELECT * FROM inbox_items
            WHERE item_class = 'ambient'
              AND archived_at IS NULL
              AND status NOT IN ('resolved', 'dismissed', 'snoozed')
            """
        var args: [any DatabaseValueConvertible] = []
        if unreadOnly {
            if !keepIDs.isEmpty {
                let placeholders = keepIDs.map { _ in "?" }.joined(separator: ", ")
                sql += " AND ((read_at IS NULL OR read_at = '') OR id IN (\(placeholders)))"
                args.append(contentsOf: keepIDs.map { $0 as any DatabaseValueConvertible })
            } else {
                sql += " AND (read_at IS NULL OR read_at = '')"
            }
        }
        sql += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
        args.append(limit)
        args.append(offset)
        return try InboxItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// Returns true if any actionable item has high priority and is pending.
    package static func hasHighPriorityAction(_ db: Database) throws -> Bool {
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM inbox_items
            WHERE item_class = 'actionable'
              AND priority = 'high'
              AND status = 'pending'
              AND archived_at IS NULL
            """) ?? 0
        return count > 0
    }

    /// Sets read_at to now for the given item only if it has not been seen before.
    package static func markSeen(_ db: Database, itemID: Int64) throws {
        try db.execute(
            sql: """
                UPDATE inbox_items SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ? AND (read_at IS NULL OR read_at = '')
                """,
            arguments: [itemID]
        )
    }
}
