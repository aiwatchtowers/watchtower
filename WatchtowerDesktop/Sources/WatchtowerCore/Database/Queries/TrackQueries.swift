import Foundation
import GRDB
import WatchtowerKit

package enum TrackQueries {

    // MARK: - Fetch

    package static func fetchAll(
        _ db: Database,
        priority: String? = nil,
        hasUpdates: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        channelID: String? = nil,
        ownership: String? = nil,
        includeDismissed: Bool = false,
        limit: Int = 200
    ) throws -> [Track] {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if !includeDismissed {
            conditions.append("dismissed_at = ''")
        }
        if let priority {
            conditions.append("priority = ?")
            args.append(priority)
        }
        if let hasUpdates {
            conditions.append("has_updates = ?")
            args.append(hasUpdates ? 1 : 0)
        }
        if let channelID {
            conditions.append("channel_ids LIKE ?")
            args.append("%\(channelID)%")
        }
        if let ownership {
            conditions.append("ownership = ?")
            args.append(ownership)
        }

        var sql = "SELECT * FROM tracks"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY has_updates DESC, updated_at DESC"
        sql += " LIMIT ?"
        args.append(limit)

        return try Track.fetchAll(db, sql: sql, arguments: StatementArguments(args))
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

    /// Mark a track as read: set read_at=now, has_updates=0, and cascade-mark related digests.
    package static func markRead(_ db: Database, id: Int) throws {
        try db.execute(sql: """
            UPDATE tracks SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), has_updates = 0
            WHERE id = ?
            """, arguments: [id])

        // Cascade: mark related digests read via related_digest_ids JSON
        let json = try String.fetchOne(
            db, sql: "SELECT related_digest_ids FROM tracks WHERE id = ?", arguments: [id]
        )
        guard let json, !json.isEmpty, json != "[]",
              let data = json.data(using: .utf8),
              let digestIDs = try? JSONDecoder().decode([Int].self, from: data)
        else { return }
        for digestID in digestIDs where digestID > 0 {
            try DigestQueries.markDigestRead(db, id: digestID)
            try DigestQueries.markAllDecisionsRead(db, digestID: digestID)
        }
    }

    /// Marks multiple tracks read in one write, cascading to related digests per track.
    package static func markRead(_ db: Database, ids: [Int]) throws {
        for id in ids {
            try markRead(db, id: id)
        }
    }

    // MARK: - Priority

    package static func updatePriority(_ db: Database, id: Int, priority: String) throws {
        try db.execute(
            sql: "UPDATE tracks SET priority = ? WHERE id = ?",
            arguments: [priority, id]
        )
        try FeedbackQueries.addFeedback(
            db,
            entityType: "track",
            entityID: "\(id)",
            rating: -1,
            comment: "priority corrected to \(priority)"
        )
    }

    // MARK: - Ownership

    package static func updateOwnership(_ db: Database, id: Int, ownership: String) throws {
        try db.execute(
            sql: "UPDATE tracks SET ownership = ? WHERE id = ?",
            arguments: [ownership, id]
        )
    }

    // MARK: - Sub-items

    package static func updateSubItems(_ db: Database, id: Int, subItems: [TrackSubItem]) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(subItems)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        try db.execute(
            sql: "UPDATE tracks SET sub_items = ? WHERE id = ?",
            arguments: [json, id]
        )
    }

    // MARK: - Dismiss / Restore

    package static func dismiss(_ db: Database, id: Int) throws {
        try db.execute(
            sql: "UPDATE tracks SET dismissed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?",
            arguments: [id]
        )
    }

    package static func restore(_ db: Database, id: Int) throws {
        try db.execute(
            sql: "UPDATE tracks SET dismissed_at = '' WHERE id = ?",
            arguments: [id]
        )
    }

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

    package static func setEnabled(_ db: Database, id: Int, enabled: Bool) throws {
        try db.execute(sql: """
            UPDATE tracks SET enabled = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, arguments: [enabled, id])
    }

    /// Edits a custom track's watch instruction in place.
    package static func updateInstruction(_ db: Database, id: Int, instruction: String) throws {
        try db.execute(sql: """
            UPDATE tracks SET instruction = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ? AND origin = 'custom'
            """, arguments: [instruction, id])
    }

    package static func fetchLastRunAt(_ db: Database, id: Int) throws -> String {
        try String.fetchOne(db, sql: "SELECT last_run_at FROM tracks WHERE id = ?", arguments: [id]) ?? ""
    }

    /// Permanently deletes a track and cascades its track_events (FK ON DELETE
    /// CASCADE). Used for user-created custom tracks; auto tracks use dismiss.
    package static func delete(_ db: Database, id: Int) throws {
        try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [id])
    }

    // MARK: - Workspace helper

    package static func fetchCurrentUserID(_ db: Database) throws -> String? {
        // current_user_id moved from workspace to slack_accounts (migration
        // 00048); pinned to account #1, mirroring Go's db.GetCurrentUserID.
        try String.fetchOne(db, sql: "SELECT current_user_id FROM slack_accounts WHERE id = 1")
    }
}
