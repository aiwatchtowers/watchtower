import Foundation
import GRDB
import WatchtowerCore

/// Read/update access to a custom track's scan-produced timeline
/// (`track_events`). Ported from the removed `ObserverQueries` event methods,
/// re-keyed from `entity_type/entity_id` to `track_id`.
enum TrackEventQueries {

    static func fetchEvents(_ db: Database, trackId: Int, limit: Int = 100) throws -> [TrackEvent] {
        try TrackEvent.fetchAll(db, sql: """
            SELECT * FROM track_events WHERE track_id = ?
            ORDER BY created_at DESC, id DESC LIMIT ?
            """, arguments: [trackId, limit])
    }

    static func unreadCount(_ db: Database, trackId: Int) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM track_events
            WHERE track_id = ? AND (read_at IS NULL OR read_at = '')
            """, arguments: [trackId]) ?? 0
    }

    static func markRead(_ db: Database, id: Int) throws {
        try db.execute(sql: """
            UPDATE track_events SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, arguments: [id])
    }

    static func setActionStatus(_ db: Database, id: Int, status: String) throws {
        try db.execute(sql: "UPDATE track_events SET action_status = ? WHERE id = ?",
                       arguments: [status, id])
    }

    /// Best-effort external link to an event's underlying source. Inbox-sourced
    /// events resolve to their Slack permalink; other source types have no
    /// single external URL (the event's own `source_refs` cover those).
    static func sourcePermalink(_ db: Database, sourceType: String, sourceId: String) throws -> String? {
        guard sourceType == "inbox", let id = Int(sourceId) else { return nil }
        let link = try String.fetchOne(db, sql: "SELECT permalink FROM inbox_items WHERE id = ?", arguments: [id])
        guard let link, !link.isEmpty else { return nil }
        return link
    }

    /// Merged timeline across all of a target's watches (custom tracks linked to
    /// it), newest-first. Reactive to inserts and to watch deletion (FK cascade).
    static func fetchForTarget(_ db: Database, targetID: Int, limit: Int = 200) throws -> [TrackEvent] {
        try TrackEvent.fetchAll(db, sql: """
            SELECT e.* FROM track_events e
            JOIN tracks t ON t.id = e.track_id
            WHERE t.linked_target_id = ?
            ORDER BY e.created_at DESC, e.id DESC
            LIMIT ?
            """, arguments: [targetID, limit])
    }
}
