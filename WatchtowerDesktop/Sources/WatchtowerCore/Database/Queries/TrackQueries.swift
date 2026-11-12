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
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.*,
                   (SELECT MAX(e.created_at) FROM track_events e WHERE e.track_id = t.id) AS last_event_at,
                   (SELECT COUNT(*) FROM track_events e
                    WHERE e.track_id = t.id AND (e.read_at IS NULL OR e.read_at = '')) AS new_events,
                   (SELECT e.summary FROM track_events e WHERE e.track_id = t.id
                    ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS latest_event_summary,
                   (SELECT e.source_id FROM track_events e WHERE e.track_id = t.id AND e.source_type = 'email'
                    ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS newest_mail_id
            FROM tracks t
            WHERE \(filter)
            ORDER BY \(order)
            """)
        let tracks = rows.map(Track.init(row:))
        // Only the active list shows the attachment chip.
        let attached = stopped ? [] : attachmentTrackIDs(db, tracks: tracks, newestMailIDs: Dictionary(
            zip(tracks, rows).compactMap { track, row in
                (row["newest_mail_id"] as String?).map { (track.id, $0) }
            }) { first, _ in first })
        return zip(tracks, rows).map { track, row in
            InboxTrackCard(
                track: track,
                lastEventAt: TrackNewsRule.lastEventAt(updatedAt: track.updatedAt, newestEventAt: row["last_event_at"]),
                newEventCount: row["new_events"] ?? 0,
                latestEventSummary: row["latest_event_summary"] ?? "",
                newestRefHasAttachment: attached.contains(track.id)
            )
        }
    }

    // MARK: - Attachment chip

    /// The tracks whose newest item carries a non-junk image (`media_items`
    /// kind `image`, never `skipped_junk`): the newest Slack source ref, or
    /// the newest mail event. One batched probe per read; the chip is a
    /// decoration, so a failed probe is logged (track ids only) and reads
    /// as no attachment — it never fails or empties the tracks read.
    private static func attachmentTrackIDs(_ db: Database, tracks: [Track], newestMailIDs: [Int: String]) -> Set<Int> {
        do {
            return try slackAttachmentTrackIDs(db, tracks: tracks)
                .union(mailAttachmentTrackIDs(db, newestMailIDs: newestMailIDs))
        } catch {
            let ids = tracks.map { String($0.id) }.joined(separator: ",")
            let code = (error as? DatabaseError)?.resultCode.rawValue ?? -1
            InboxLog.logger.error("track attachment probe failed (sqlite \(code)) for tracks \(ids, privacy: .public)")
            return []
        }
    }

    /// Slack: each track's newest source ref, matched through `messages`
    /// (its `ts_unix` index; the media row's channel may be namespaced
    /// `<account>:<channel>`) to an image `media_items` row.
    private static func slackAttachmentTrackIDs(_ db: Database, tracks: [Track]) throws -> Set<Int> {
        let refs: [[String: Any]] = tracks.compactMap { track in
            guard let ref = track.newestSourceRef, let channel = ref.channelID, !channel.isEmpty else { return nil }
            let seconds = Double(ref.ts.split(separator: ".").first ?? "") ?? 0
            return ["track": track.id, "channel": channel, "suffix": ":" + channel, "ts": ref.ts, "seconds": seconds]
        }
        guard !refs.isEmpty else { return [] }
        return try Set(Int.fetchAll(db, sql: """
            SELECT DISTINCT json_extract(p.value, '$.track')
            FROM json_each(?) p
            CROSS JOIN messages msg
            WHERE msg.ts_unix = json_extract(p.value, '$.seconds') AND msg.ts = json_extract(p.value, '$.ts')
              AND (msg.channel_id = json_extract(p.value, '$.channel')
                   OR substr(msg.channel_id, -length(json_extract(p.value, '$.suffix'))) = json_extract(p.value, '$.suffix'))
              AND EXISTS (
                SELECT 1 FROM media_items m
                WHERE m.slack_channel_id = msg.channel_id AND m.slack_ts = msg.ts
                  AND m.parent_kind = 'slack' AND m.kind = 'image' AND m.status != 'skipped_junk')
            """, arguments: [json(refs)]))
    }

    /// Mail: the watch scan records mail as `source_type = 'email'` with
    /// `source_id` = the `list_emails` id, the Gmail message id or
    /// `<uidvalidity>-<uid>` for IMAP (`internal/db/emails_read.go`
    /// `imapEmailIDExpr`). Matched per account so the account-led
    /// `media_items` indexes serve.
    private static func mailAttachmentTrackIDs(_ db: Database, newestMailIDs: [Int: String]) throws -> Set<Int> {
        var gmail: [[String: Any]] = []
        var imap: [[String: Any]] = []
        for (trackID, id) in newestMailIDs where !id.isEmpty {
            if let key = imapKey(id) {
                imap.append(["track": trackID, "uidvalidity": key.uidvalidity, "uid": key.uid])
            } else {
                gmail.append(["track": trackID, "id": id])
            }
        }
        var found: Set<Int> = []
        if !gmail.isEmpty {
            found.formUnion(try Int.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(p.value, '$.track')
                FROM json_each(?) p
                CROSS JOIN google_accounts a
                WHERE EXISTS (
                    SELECT 1 FROM media_items m
                    WHERE m.gmail_account_id = a.id AND m.gmail_message_id = json_extract(p.value, '$.id')
                      AND m.parent_kind = 'gmail' AND m.kind = 'image' AND m.status != 'skipped_junk')
                """, arguments: [json(gmail)]))
        }
        if !imap.isEmpty {
            found.formUnion(try Int.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(p.value, '$.track')
                FROM json_each(?) p
                CROSS JOIN email_accounts a
                WHERE EXISTS (
                    SELECT 1 FROM media_items m
                    WHERE m.imap_account_id = a.id
                      AND m.imap_uidvalidity = json_extract(p.value, '$.uidvalidity')
                      AND m.imap_uid = json_extract(p.value, '$.uid')
                      AND m.parent_kind = 'imap' AND m.kind = 'image' AND m.status != 'skipped_junk')
                """, arguments: [json(imap)]))
        }
        return found
    }

    /// `<uidvalidity>-<uid>` as two integers; nil for any other id (Gmail's).
    private static func imapKey(_ id: String) -> (uidvalidity: Int64, uid: Int64)? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let uidvalidity = Int64(parts[0]), let uid = Int64(parts[1]) else { return nil }
        return (uidvalidity, uid)
    }

    private static func json(_ value: [[String: Any]]) throws -> String {
        String(bytes: try JSONSerialization.data(withJSONObject: value), encoding: .utf8) ?? "[]"
    }

    /// Those of `ids` that are stopped (`dismissed_at` set) or still active.
    package static func ids(_ db: Database, among ids: [Int64], stopped: Bool) throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        let list = "[" + ids.map(String.init).joined(separator: ",") + "]"
        return try Int64.fetchAll(db, sql: """
            SELECT id FROM tracks
            WHERE (dismissed_at != '') = ? AND id IN (SELECT value FROM json_each(?))
            """, arguments: [stopped, list])
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
    /// Best-effort, unchecked: a track deleted meanwhile has nothing left to
    /// read, so a zero-row write is the desired end state, not a failure.
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
        // Before the feedback row: a vanished track must not leave a correction behind.
        try db.requireUpdated("track", id: id)
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
        try db.requireUpdated("track", id: id)
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
        try db.requireUpdated("track", id: id)
    }

    // MARK: - Dismiss / Restore

    package static func dismiss(_ db: Database, id: Int) throws {
        try db.execute(
            sql: "UPDATE tracks SET dismissed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?",
            arguments: [id]
        )
        try db.requireUpdated("track", id: id)
    }

    package static func restore(_ db: Database, id: Int) throws {
        try db.execute(
            sql: "UPDATE tracks SET dismissed_at = '' WHERE id = ?",
            arguments: [id]
        )
        try db.requireUpdated("track", id: id)
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
        try db.requireUpdated("track", id: id)
    }

    /// Edits a custom track's watch instruction in place.
    package static func updateInstruction(_ db: Database, id: Int, instruction: String) throws {
        try db.execute(sql: """
            UPDATE tracks SET instruction = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ? AND origin = 'custom'
            """, arguments: [instruction, id])
        try db.requireUpdated("track", id: id)
    }

    package static func fetchLastRunAt(_ db: Database, id: Int) throws -> String {
        try String.fetchOne(db, sql: "SELECT last_run_at FROM tracks WHERE id = ?", arguments: [id]) ?? ""
    }

    /// Permanently deletes a track and cascades its track_events (FK ON DELETE
    /// CASCADE). Used for user-created custom tracks; auto tracks use dismiss.
    package static func delete(_ db: Database, id: Int) throws {
        try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [id])
    }
}
