import Foundation
import GRDB

package enum TrackQueries {

    // MARK: - Fetch

    /// The non-dismissed tracks, updated ones first, then newest update.
    package static func fetchAll(_ db: Database, limit: Int = 200) throws -> [Track] {
        try Track.fetchAll(db, sql: """
            SELECT * FROM tracks WHERE dismissed_at = ''
            ORDER BY has_updates DESC, updated_at DESC
            LIMIT ?
            """, arguments: [limit])
    }

    /// Every non-dismissed track — or, `stopped`, every dismissed one — with
    /// its latest activity (the Inbox root's Track my threads list; no limit,
    /// F1): `lastEventAt` is the later of the track's
    /// `updated_at` and its newest event, `newEventCount` its unread events.
    package static func fetchInboxCards(_ db: Database, stopped: Bool = false) throws -> [InboxTrackCard] {
        // Stopped = dismissed (TRACKS-07): listed only in Track my threads'
        // Stopped fold, so the owner can restore one; newest stop first.
        let filter = stopped ? "t.dismissed_at != ''" : "t.dismissed_at = ''"
        let order = stopped ? "t.dismissed_at DESC, t.id DESC" : "t.has_updates DESC, t.updated_at DESC, t.id DESC"
        return try inboxCards(db, filter: filter, order: order)
    }

    /// The tracks `ids` as the Inbox draws them, whatever their state (the
    /// tower's feed decides which are listed).
    package static func fetchInboxCards(_ db: Database, ids: [Int64]) throws -> [InboxTrackCard] {
        guard !ids.isEmpty else { return [] }
        return try inboxCards(db, filter: "t.id IN (\(ids.map(String.init).joined(separator: ",")))", order: "t.id")
    }

    private static func inboxCards(_ db: Database, filter: String, order: String) throws -> [InboxTrackCard] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.*,
                   (SELECT MAX(e.created_at) FROM track_events e WHERE e.track_id = t.id) AS last_event_at,
                   (SELECT COUNT(*) FROM track_events e
                    WHERE e.track_id = t.id AND (e.read_at IS NULL OR e.read_at = '')) AS new_events
            FROM tracks t
            WHERE \(filter)
            ORDER BY \(order)
            """)
        return rows.map { row in
            let track = Track(row: row)
            let updated = AutomationDates.parse(track.updatedAt)
            let event = AutomationDates.parse(row["last_event_at"] as String?)
            let last = [updated, event].compactMap { $0 }.max() ?? Date(timeIntervalSince1970: 0)
            return InboxTrackCard(track: track, lastEventAt: last, newEventCount: row["new_events"] ?? 0)
        }
    }

    package static func fetchUpdatedTracks(_ db: Database) throws -> [Track] {
        try Track.fetchAll(
            db,
            sql: "SELECT * FROM tracks WHERE has_updates = 1 ORDER BY updated_at DESC"
        )
    }

    package static func fetchByID(_ db: Database, id: Int) throws -> Track? {
        try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id])
    }

    package static func fetchByIDs(_ db: Database, ids: [Int]) throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try Track.fetchAll(
            db,
            sql: "SELECT * FROM tracks WHERE id IN (\(placeholders))",
            arguments: StatementArguments(ids)
        )
    }

    // MARK: - Counts

    package static func fetchCounts(_ db: Database) throws -> (total: Int, updated: Int) {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE dismissed_at = ''") ?? 0
        let updated = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM tracks WHERE has_updates = 1 AND dismissed_at = ''"
        ) ?? 0
        return (total, updated)
    }

    package static func fetchOwnershipCounts(_ db: Database) throws -> [String: Int] {
        var result: [String: Int] = [:]
        let rows = try Row.fetchAll(
            db, sql: "SELECT ownership, COUNT(*) as cnt FROM tracks GROUP BY ownership"
        )
        for row in rows {
            let key: String = row["ownership"]
            let count: Int = row["cnt"]
            result[key] = count
        }
        return result
    }

    // MARK: - Mark read

    // MARK: - Priority

    // MARK: - Ownership

    // MARK: - Sub-items

    // MARK: - Dismiss / Restore

    // MARK: - Custom tracks

    package static func fetchCustomTracks(_ db: Database) throws -> [Track] {
        try Track.fetchAll(db, sql: """
            SELECT * FROM tracks WHERE origin = 'custom' AND dismissed_at = ''
            ORDER BY updated_at DESC
            """)
    }

    /// Newest custom track by id — used to resolve the id of a just-created custom
    /// track after `CustomTrackManagementSheet`'s `onCreated` yields a `TrackDraft`
    /// with no id (dashboard create-track conversion, DASH-03).
    package static func fetchLatestCustom(_ db: Database) throws -> Track? {
        try Track.fetchOne(db, sql: """
            SELECT * FROM tracks WHERE origin = 'custom' ORDER BY id DESC LIMIT 1
            """)
    }

    /// Custom tracks (watches) linked to a given target, newest first.
    package static func fetchByLinkedTarget(_ db: Database, targetID: Int) throws -> [Track] {
        try Track.fetchAll(db, sql: """
            SELECT * FROM tracks
            WHERE origin = 'custom' AND linked_target_id = ? AND dismissed_at = ''
            ORDER BY updated_at DESC
            """, arguments: [targetID])
    }

    package static func fetchLastRunAt(_ db: Database, id: Int) throws -> String {
        try String.fetchOne(db, sql: "SELECT last_run_at FROM tracks WHERE id = ?", arguments: [id]) ?? ""
    }

}
