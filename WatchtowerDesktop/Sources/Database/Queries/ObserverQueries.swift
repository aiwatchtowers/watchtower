import Foundation
import GRDB

enum ObserverQueries {

    // MARK: - Observers

    static func fetchForEntity(_ db: Database, entityType: String = "target", entityId: Int) throws -> [Observer] {
        try Observer.fetchAll(db, sql: """
            SELECT * FROM observers WHERE entity_type = ? AND entity_id = ? ORDER BY created_at
            """, arguments: [entityType, entityId])
    }

    @discardableResult
    static func create(_ db: Database,
                       entityType: String = "target",
                       entityId: Int,
                       name: String,
                       instruction: String) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO observers (entity_type, entity_id, name, instruction, enabled)
            VALUES (?, ?, ?, ?, 1)
            """, arguments: [entityType, entityId, name, instruction])
        return db.lastInsertedRowID
    }

    static func update(_ db: Database, id: Int, name: String, instruction: String) throws {
        try db.execute(sql: """
            UPDATE observers SET name = ?, instruction = ?,
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, arguments: [name, instruction, id])
    }

    static func setEnabled(_ db: Database, id: Int, enabled: Bool) throws {
        try db.execute(sql: """
            UPDATE observers SET enabled = ?,
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, arguments: [enabled ? 1 : 0, id])
    }

    static func delete(_ db: Database, id: Int) throws {
        try db.execute(sql: "DELETE FROM observers WHERE id = ?", arguments: [id])
    }

    // MARK: - Events

    static func fetchEvents(_ db: Database, entityType: String = "target", entityId: Int, limit: Int = 100) throws -> [ObserverEvent] {
        try ObserverEvent.fetchAll(db, sql: """
            SELECT * FROM observer_events WHERE entity_type = ? AND entity_id = ?
            ORDER BY created_at DESC, id DESC LIMIT ?
            """, arguments: [entityType, entityId, limit])
    }

    static func unreadCount(_ db: Database, entityType: String = "target", entityId: Int) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM observer_events
            WHERE entity_type = ? AND entity_id = ? AND (read_at IS NULL OR read_at = '')
            """, arguments: [entityType, entityId]) ?? 0
    }

    static func markRead(_ db: Database, id: Int) throws {
        try db.execute(sql: """
            UPDATE observer_events SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, arguments: [id])
    }

    static func setActionStatus(_ db: Database, id: Int, status: String) throws {
        try db.execute(sql: "UPDATE observer_events SET action_status = ? WHERE id = ?",
                       arguments: [status, id])
    }

    /// Best-effort external link to an event's underlying source. Inbox-sourced
    /// events resolve to their Slack permalink; other source types have no single
    /// external URL (the event's own `source_refs` cover those when present).
    static func sourcePermalink(_ db: Database, sourceType: String, sourceId: String) throws -> String? {
        guard sourceType == "inbox", let id = Int(sourceId) else { return nil }
        let link = try String.fetchOne(db, sql: "SELECT permalink FROM inbox_items WHERE id = ?", arguments: [id])
        guard let link, !link.isEmpty else { return nil }
        return link
    }
}
